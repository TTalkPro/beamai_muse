%% @doc PDF form operations through the Node/pdf-lib port program
%% `sidecars/pdf/index.mjs' (designs/04-integrations.md §2,
%% designs/ref/openmuse-integrations-spec.md §5.3-§5.5).
%%
%% One gen_server owns a small pool of port processes (app env
%% `{muse_integ, [{pdf_pool_size, N}]}', default 2). Ports are spawned lazily
%% on first use, so a node without `node' installed still boots; such calls
%% fail with 502. Each request is dispatched to an idle port and gets 20 s; on
%% timeout the OS process is killed, the slot is respawned on next use and the
%% caller gets `{error, {502, <<"PDF helper timed out">>}}'. Requests beyond
%% the pool size wait in a FIFO queue (their 20 s starts at dispatch). The
%% timeout can be overridden with `{muse_integ, [{pdf_timeout, Ms}]}' (tests).
%%
%% The sidecar command is `muse_config:get(pdf_sidecar)' (default
%% `node sidecars/pdf/index.mjs'), split on whitespace and run without a shell.
%% A bare executable name is looked up on PATH; a relative path (executable
%% or argument) is resolved against the project root, which is also the
%% port's working directory. The root is, in order: app env
%% `{muse_integ, [{root, Dir}]}'; the nearest ancestor of
%% `code:lib_dir(muse_integ)' containing `sidecars/' (covers `_build/*/lib/'
%% in development and `<release>/lib/muse_integ-*' in a release that ships
%% `sidecars/'); the current directory.
%%
%% Sidecar PdfErrors become `{error, {422, Message}}'. The size and `%PDF-'
%% header checks also run here first so oversize inputs never cross the port.
%% `sample/0' reads the pre-generated `priv/sample-permission-slip.pdf';
%% `generate_sample/0' asks the sidecar to build a fresh one.
-module(muse_pdf).
-behaviour(gen_server).

-export([start_link/0, inspect/1, fill/2, sample/0, generate_sample/0, root/0, sidecar_port/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_PDF_BYTES, 10485760).
-define(INVALID, <<"Invalid PDF: expected nonempty PDF bytes up to 10 MiB">>).
-define(DEFAULT_CMD, <<"node sidecars/pdf/index.mjs">>).
-define(SAMPLE_FILE, "sample-permission-slip.pdf").

-type field() :: #{binary() => binary()}.
-type inspection() :: #{binary() => non_neg_integer() | [field()]}.
-type error() :: {error, {422 | 502, binary()}}.
-export_type([inspection/0, field/0]).

-record(slot, {port :: port() | undefined,
               os_pid :: integer() | undefined,
               job :: {gen_server:from(), atom(), reference()} | undefined}).
-record(state, {slots :: #{pos_integer() => #slot{}},
                queue :: queue:queue({gen_server:from(), atom(), binary()}),
                timeout :: pos_integer()}).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc `inspectPdf': page count and every terminal form field
%% (`#{<<"name">>, <<"value">>, <<"type">> := text | checkbox | unsupported}').
-spec inspect(binary()) -> {ok, inspection()} | error().
inspect(Pdf) when is_binary(Pdf) ->
    maybe
        ok ?= precheck(Pdf),
        request(inspect, #{op => inspect, pdf => base64:encode(Pdf)})
    end.

%% @doc `fillPdf': text fields take binaries, checkboxes booleans. Returns the
%% new PDF with actions stripped and appearances regenerated.
-spec fill(binary(), #{binary() => binary() | boolean()}) -> {ok, binary()} | error().
fill(Pdf, Values) when is_binary(Pdf), is_map(Values) ->
    maybe
        ok ?= precheck(Pdf),
        ok ?= check_values(Values),
        request(fill, #{op => fill, pdf => base64:encode(Pdf), values => Values})
    end.

%% @doc The bundled synthetic permission form (spec §5.5).
-spec sample() -> {ok, binary()} | {error, file:posix() | badarg}.
sample() ->
    file:read_file(filename:join(code:priv_dir(muse_integ), ?SAMPLE_FILE)).

%% @doc `createSamplePdf' run in the sidecar (used to produce the priv file).
-spec generate_sample() -> {ok, binary()} | error().
generate_sample() ->
    request(sample, #{op => sample}).

%% @doc Directory the sidecar command is resolved against (see module doc).
-spec root() -> file:filename().
root() ->
    case application:get_env(muse_integ, root) of
        {ok, Dir} -> Dir;
        undefined ->
            case code:lib_dir(muse_integ) of
                {error, bad_name} -> cwd();
                Lib -> find_root(filename:absname(Lib))
            end
    end.

%% Client helpers

precheck(Pdf) ->
    Head = binary:part(Pdf, 0, min(byte_size(Pdf), 1024)),
    case Pdf =/= <<>> andalso byte_size(Pdf) =< ?MAX_PDF_BYTES
        andalso binary:match(Head, <<"%PDF-">>) =/= nomatch of
        true -> ok;
        false -> {error, {422, ?INVALID}}
    end.

%% Names and text must be UTF-8 to travel as JSON; other shapes are left to
%% the sidecar so its messages (`PDF text field requires a string: ...')
%% stay authoritative.
check_values(Values) ->
    Bad = [K || K := V <- Values,
                not utf8(K) orelse (is_binary(V) andalso not utf8(V))],
    case Bad of
        [] -> ok;
        _ -> {error, {422, <<"Invalid PDF field values: names and text must be UTF-8">>}}
    end.

utf8(B) when is_binary(B) ->
    is_binary(unicode:characters_to_binary(B, utf8, utf8));
utf8(_) ->
    false.

request(Op, Request) ->
    gen_server:call(?MODULE, {request, Op, muse_json:encode(Request)}, infinity).

%% gen_server

-spec init([]) -> {ok, #state{}}.
init([]) ->
    process_flag(trap_exit, true),
    Size = application:get_env(muse_integ, pdf_pool_size, 2),
    Slots = maps:from_list([{I, #slot{}} || I <- lists:seq(1, Size)]),
    Timeout = application:get_env(muse_integ, pdf_timeout, 20000),
    {ok, #state{slots = Slots, queue = queue:new(), timeout = Timeout}}.

-spec handle_call(term(), gen_server:from(), #state{}) -> {noreply, #state{}} | {reply, term(), #state{}}.
handle_call({request, Op, Json}, From, State = #state{queue = Q}) ->
    {noreply, dispatch(State#state{queue = queue:in({From, Op, Json}, Q)})};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info({Port, {data, Data}}, State) when is_port(Port) ->
    case find_slot(Port, State) of
        {I, Slot = #slot{job = {From, Op, TRef}}} ->
            _ = erlang:cancel_timer(TRef),
            gen_server:reply(From, decode_reply(Op, Data)),
            {noreply, dispatch(put_slot(I, Slot#slot{job = undefined}, State))};
        _ ->
            {noreply, State}
    end;
handle_info({Port, {exit_status, _}}, State) when is_port(Port) ->
    case find_slot(Port, State) of
        {I, #slot{job = Job}} ->
            fail_job(Job, <<"PDF helper exited unexpectedly">>),
            {noreply, dispatch(put_slot(I, #slot{}, State))};
        none ->
            {noreply, State}
    end;
handle_info({timeout, TRef, {pdf_job, I}}, State = #state{slots = Slots}) ->
    case maps:get(I, Slots) of
        Slot = #slot{job = {_, _, TRef} = Job} ->
            kill(Slot),
            fail_job(Job, <<"PDF helper timed out">>),
            {noreply, dispatch(put_slot(I, #slot{}, State))};
        _ ->
            {noreply, State}
    end;
handle_info({'EXIT', _Port, _Reason}, State) ->
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{slots = Slots}) ->
    lists:foreach(fun kill/1, maps:values(Slots)).

%% Pool internals

dispatch(State = #state{slots = Slots, queue = Q}) ->
    Idle = [I || I := #slot{job = undefined} <- Slots],
    case {lists:sort(Idle), queue:out(Q)} of
        {[I | _], {{value, {From, Op, Json}}, Q1}} ->
            dispatch(run(I, From, Op, Json, State#state{queue = Q1}));
        _ ->
            State
    end.

run(I, From, Op, Json, State = #state{slots = Slots, timeout = Timeout}) ->
    case ensure_port(maps:get(I, Slots)) of
        {ok, Slot = #slot{port = Port}} ->
            true = port_command(Port, Json),
            TRef = erlang:start_timer(Timeout, self(), {pdf_job, I}),
            put_slot(I, Slot#slot{job = {From, Op, TRef}}, State);
        {error, Msg} ->
            gen_server:reply(From, {error, {502, Msg}}),
            State
    end.

ensure_port(Slot = #slot{port = Port}) when is_port(Port) ->
    {ok, Slot};
ensure_port(Slot) ->
    try spawn_port() of
        Port ->
            OsPid = case erlang:port_info(Port, os_pid) of
                        {os_pid, P} -> P;
                        undefined -> undefined
                    end,
            {ok, Slot#slot{port = Port, os_pid = OsPid}}
    catch
        error:Reason ->
            logger:warning("muse_pdf: cannot start PDF sidecar: ~p", [Reason]),
            {error, <<"PDF helper is unavailable">>}
    end.

spawn_port() ->
    sidecar_port(muse_config:get(pdf_sidecar, ?DEFAULT_CMD), []).

%% @doc Open a `{packet,4}' binary port running the sidecar command `Cmd'
%% (split on whitespace, no shell; relative paths against `root/0', which is
%% also the working directory). The program gets PATH, HOME, the locale and
%% the variables named in `KeepEnv', none of the server's secrets (every
%% other variable is unset). Raises if the executable is missing. The mail
%% sidecar (muse_mail_client) is started the same way.
-spec sidecar_port(binary(), [string()]) -> port().
sidecar_port(Cmd, KeepEnv) ->
    Root = root(),
    [Exe | Args] = string:lexemes(unicode:characters_to_list(Cmd), " \t"),
    open_port({spawn_executable, executable(Exe, Root)},
              [{args, Args}, {cd, Root}, {env, env(KeepEnv)}, {packet, 4}, binary, exit_status, use_stdio]).

%% The helper parses untrusted PDFs: it gets PATH, HOME and the locale, and
%% none of the server's secrets (every other variable is unset).
env(Extra) ->
    Keep = ["PATH", "HOME", "LANG", "LC_ALL", "TZ" | Extra],
    [{Name, false} || Var <- os:getenv(),
                      [Name | _] <- [string:split(Var, "=")],
                      Name =/= "", not lists:member(Name, Keep)].

executable(Exe, Root) ->
    case filename:pathtype(Exe) of
        absolute -> Exe;
        _ ->
            case lists:member($/, Exe) of
                true -> filename:join(Root, Exe);
                false ->
                    case os:find_executable(Exe) of
                        false -> error({executable_not_found, Exe});
                        Path -> Path
                    end
            end
    end.

kill(#slot{port = undefined}) ->
    ok;
kill(#slot{port = Port, os_pid = OsPid}) ->
    %% port_close only closes stdin; a wedged helper needs SIGKILL.
    _ = case is_integer(OsPid) of
            true -> sigkill(OsPid);
            false -> ok
        end,
    _ = catch port_close(Port),
    ok.

fail_job(undefined, _Msg) ->
    ok;
fail_job({From, _Op, TRef}, Msg) ->
    _ = erlang:cancel_timer(TRef),
    gen_server:reply(From, {error, {502, Msg}}).

find_slot(Port, #state{slots = Slots}) ->
    case [{I, S} || I := S = #slot{port = P} <- Slots, P =:= Port] of
        [Found] -> Found;
        [] -> none
    end.

put_slot(I, Slot, State = #state{slots = Slots}) ->
    State#state{slots = Slots#{I := Slot}}.

decode_reply(Op, Data) ->
    case muse_json:decode(Data) of
        {ok, #{<<"ok">> := Ok}} -> ok_result(Op, Ok);
        {ok, #{<<"error">> := <<"PdfError">>, <<"message">> := Msg}} when is_binary(Msg) ->
            {error, {422, Msg}};
        _ ->
            {error, {502, <<"PDF helper returned an invalid response">>}}
    end.

ok_result(inspect, Ok = #{<<"pageCount">> := N, <<"fields">> := Fields})
  when is_integer(N), is_list(Fields) ->
    {ok, maps:with([<<"pageCount">>, <<"fields">>], Ok)};
ok_result(Op, #{<<"pdf">> := B64}) when Op =/= inspect, is_binary(B64) ->
    {ok, base64:decode(B64)};
ok_result(_, _) ->
    {error, {502, <<"PDF helper returned an invalid response">>}}.

%% Root discovery

find_root(Dir) ->
    case filelib:is_dir(filename:join(Dir, "sidecars")) of
        true -> Dir;
        false ->
            case filename:dirname(Dir) of
                Dir -> cwd();
                Parent -> find_root(Parent)
            end
    end.

cwd() ->
    {ok, Dir} = file:get_cwd(),
    Dir.

%% SIGKILL without a shell.
sigkill(OsPid) ->
    case os:find_executable("kill") of
        false -> ok;
        Kill ->
            P = open_port({spawn_executable, Kill}, [{args, ["-9", integer_to_list(OsPid)]}, exit_status]),
            receive {P, {exit_status, _}} -> ok after 2000 -> catch port_close(P), ok end
    end.
