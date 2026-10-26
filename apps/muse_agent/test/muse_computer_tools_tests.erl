-module(muse_computer_tools_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tool set of OpenMuse computer-tools.ts (engine spec §8.1). The service
%% (`muse_computer`) is mocked; its schemas are the real ones. The computer
%% of a scope (pool, not in OpenMuse) is the ref `{Owner, "pc-" ++ Scope}`.

-define(O, <<"owner-1">>).
-define(REF, {?O, <<"pc-task:t1">>}).
-define(FAILED, <<"Computer operation failed">>).
-define(NAMES, [<<"computer_status">>, <<"start_computer">>, <<"stop_computer">>,
                <<"run_computer_command">>, <<"list_computer_files">>,
                <<"read_computer_file">>, <<"write_computer_file">>, <<"mkdir_computer">>,
                <<"import_computer_pdf">>, <<"export_computer_pdf">>]).

setup(Provider) ->
    meck:new(muse_computer, [passthrough]),
    meck:expect(muse_computer, provider, fun() -> Provider end),
    meck:expect(muse_computer, ref, fun(O, S) -> {O, <<"pc-", S/binary>>} end),
    meck:expect(muse_computer, ensure, fun(O, S) -> {O, <<"pc-", S/binary>>} end),
    meck:expect(muse_computer, ensure_running, fun(_) -> ok end),
    meck:expect(muse_computer, snapshot, fun(O) -> #{<<"status">> => <<"stopped">>, <<"owner">> => O} end),
    meck:expect(muse_computer, start, fun(_) -> {ok, #{<<"status">> => <<"running">>}} end),
    meck:expect(muse_computer, stop, fun(_) -> {ok, #{<<"status">> => <<"stopped">>}} end),
    meck:expect(muse_computer, execute,
                fun(_, Args, _) -> {ok, Args#{<<"status">> => <<"succeeded">>}} end),
    meck:expect(muse_computer, list, fun(_, P) -> {ok, #{<<"path">> => P, <<"entries">> => []}} end),
    meck:expect(muse_computer, read, fun(_, P) -> {ok, #{<<"path">> => P, <<"text">> => <<"hi">>}} end),
    meck:expect(muse_computer, write, fun(_, P, _) -> {ok, #{<<"path">> => P}} end),
    meck:expect(muse_computer, mkdir, fun(_, P) -> {ok, #{<<"path">> => P}} end),
    meck:expect(muse_computer, import_pdf, fun(_, P, _) -> {ok, #{<<"path">> => P}} end),
    meck:expect(muse_computer, export_pdf, fun(_, _) -> {ok, #{<<"id">> => <<"art-1">>}} end),
    ok.

cleanup(_) ->
    meck:unload(muse_computer).

with(Provider, Tests) ->
    {foreach, fun() -> setup(Provider) end, fun cleanup/1, Tests}.

tools() -> tools(<<"task:t1">>, fun() -> ok end).

tools(Scope, Before) -> muse_computer_tools:tools(?O, Scope, Before).

with_id(Map) -> Map#{<<"computerId">> => <<"pc-task:t1">>}.

spec(Name) -> spec(Name, tools()).

spec(Name, Tools) ->
    [S] = [S || #{name := N} = S <- Tools, N =:= Name],
    S.

call(Name, Args) -> call(Name, Args, beamai_context:new()).

call(Name, Args, Ctx) -> call_in(spec(Name), Args, Ctx).

call_in(#{handler := H}, Args, Ctx) -> H(Args, Ctx).

err(Msg) -> {ok, #{<<"error">> => Msg}}.

%% Shape

docker_test_() ->
    with(<<"docker">>,
         [{"tool names and order", fun() -> ?assertEqual(?NAMES, [N || #{name := N} <- tools()]) end},
          {"docker descriptions", fun docker_descriptions/0},
          {"parameter DSL", fun params/0}]).

docker_descriptions() ->
    network(<<"bridge">>, #{}),
    ?assertEqual(
       [<<"Inspect the real Docker computer status and durable command receipts">>,
        %% COMPUTER_NETWORK=bridge (the default); `none` keeps OpenMuse's text
        <<"Start the configured private Linux computer (optional: it starts by itself on first use)">>,
        <<"Stop the private Linux computer while preserving /workspace">>,
        <<"Run bash only inside the private computer and return its persisted output and exit receipt">>,
        <<"List files in the computer workspace">>,
        <<"Read a UTF-8 file up to 256 KB inside /workspace">>,
        <<"Save a UTF-8 file up to 256 KB inside /workspace">>,
        <<"Create a directory inside /workspace">>,
        <<"Copy an owned app PDF into the computer without network access">>,
        <<"Import a completed workspace PDF into app Files">>],
       [D || #{description := D} <- tools()]),
    persistent_term:erase({muse_config, config}).

params() ->
    Str = fun(Req) -> #{type => string, required => Req} end,
    P = fun(Name) -> maps:get(parameters, spec(Name)) end,
    ?assertEqual(#{}, P(<<"computer_status">>)),
    ?assertEqual(#{}, P(<<"start_computer">>)),
    ?assertEqual(#{}, P(<<"stop_computer">>)),
    ?assertEqual(#{<<"command">> => Str(true), <<"cwd">> => Str(false),
                   <<"operationId">> => Str(true)},
                 P(<<"run_computer_command">>)),
    [?assertEqual(#{<<"path">> => Str(true)}, P(N))
     || N <- [<<"list_computer_files">>, <<"read_computer_file">>, <<"mkdir_computer">>,
              <<"export_computer_pdf">>]],
    ?assertEqual(#{<<"path">> => Str(true), <<"text">> => Str(true)},
                 P(<<"write_computer_file">>)),
    ?assertEqual(#{<<"path">> => Str(true), <<"fileId">> => Str(true)},
                 P(<<"import_computer_pdf">>)),
    ?assertMatch(#{serial := true}, spec(<<"run_computer_command">>)).

%% Behaviour

behaviour_test_() ->
    with(<<"docker">>,
         [{"status and lifecycle", fun lifecycle/0},
          {"computer scopes: thread and task", fun scopes/0},
          {"auto-start on first use", fun auto_start/0},
          {"idempotency key is <scope>:<operationId>", fun idempotency/0},
          {"run pid is a cancel source", fun cancel_pid/0},
          {"argument validation", fun validation/0},
          {"file tools forward their arguments", fun files/0},
          {"Before runs first and its throws become errors", fun before/0},
          {"service errors and crashes map to error results", fun errors/0}]).

lifecycle() ->
    ?assertEqual({ok, with_id(#{<<"status">> => <<"stopped">>, <<"owner">> => ?REF})},
                 call(<<"computer_status">>, #{})),
    %% status and stop never create the computer's record
    ?assertNot(meck:called(muse_computer, ensure, '_')),
    ?assertEqual({ok, with_id(#{<<"status">> => <<"running">>})}, call(<<"start_computer">>, #{})),
    ?assertEqual({ok, with_id(#{<<"status">> => <<"stopped">>})}, call(<<"stop_computer">>, #{})),
    ?assert(meck:called(muse_computer, start, [?REF])),
    ?assert(meck:called(muse_computer, stop, [?REF])),
    ?assert(meck:called(muse_computer, ensure, [?O, <<"task:t1">>])).

%% One computer per conversation (thread) and per task; operation ids stay
%% per request.
scopes() ->
    ?assertEqual(<<"thread:thread-1">>, muse_computer_tools:computer_scope(<<"chat:thread-1:msg-2">>)),
    ?assertEqual(<<"task:t1">>, muse_computer_tools:computer_scope(<<"task:t1">>)),
    Chat = muse_computer_tools:tools(?O, <<"thread:th-9">>, <<"chat:th-9:m-1">>, fun() -> ok end),
    {ok, R} = call_in(spec(<<"run_computer_command">>, Chat),
                      #{<<"command">> => <<"pwd">>, <<"operationId">> => <<"o">>}, beamai_context:new()),
    ?assertEqual(<<"pc-thread:th-9">>, maps:get(<<"computerId">>, R)),
    ?assert(meck:called(muse_computer, execute,
                        [{?O, <<"pc-thread:th-9">>}, '_',
                         #{idempotency_key => <<"chat:th-9:m-1:o">>, cancel => [], auto_start => true}])),
    %% two scopes, two computers
    Other = muse_computer_tools:tools(?O, <<"task:t2">>, <<"task:t2">>, fun() -> ok end),
    {ok, _} = call_in(spec(<<"run_computer_command">>, Other),
                      #{<<"command">> => <<"pwd">>, <<"operationId">> => <<"o">>}, beamai_context:new()),
    ?assert(meck:called(muse_computer, execute, [{?O, <<"pc-task:t2">>}, '_', '_'])).

%% Commands start the computer themselves (`auto_start`); file tools call
%% ensure_running first and fail with its error.
auto_start() ->
    {ok, _} = call(<<"read_computer_file">>, #{<<"path">> => <<"/workspace/a">>}),
    ?assert(meck:called(muse_computer, ensure_running, [?REF])),
    Off = <<"Computer is not configured. Enable COMPUTER_ENABLED and build the local computer image.">>,
    meck:expect(muse_computer, ensure_running, fun(_) -> {error, {503, Off}} end),
    meck:reset(muse_computer),
    ?assertEqual(err(Off), call(<<"list_computer_files">>, #{<<"path">> => <<"/workspace">>})),
    ?assertNot(meck:called(muse_computer, list, '_')).

idempotency() ->
    {ok, R} = call(<<"run_computer_command">>,
                   #{<<"command">> => <<"  ls -la  ">>, <<"operationId">> => <<"op-1">>}),
    ?assertEqual(with_id(#{<<"command">> => <<"ls -la">>, <<"cwd">> => <<"/workspace">>,
                           <<"status">> => <<"succeeded">>}), R),
    ?assert(meck:called(muse_computer, execute,
                        [?REF, #{<<"command">> => <<"ls -la">>, <<"cwd">> => <<"/workspace">>},
                         #{idempotency_key => <<"task:t1:op-1">>, cancel => [], auto_start => true}])),
    Chat = tools(<<"chat:thread-1:msg-2">>, fun() -> ok end),
    {ok, _} = call_in(spec(<<"run_computer_command">>, Chat),
                      #{<<"command">> => <<"pwd">>, <<"cwd">> => <<"/workspace/x">>,
                        <<"operationId">> => <<"a:b">>}, beamai_context:new()),
    ?assert(meck:called(muse_computer, execute,
                        [{?O, <<"pc-thread:thread-1">>}, #{<<"command">> => <<"pwd">>, <<"cwd">> => <<"/workspace/x">>},
                         #{idempotency_key => <<"chat:thread-1:msg-2:a:b">>, cancel => [], auto_start => true}])).

cancel_pid() ->
    Run = spawn(fun() -> receive stop -> ok end end),
    Ctx = beamai_context:with_state(beamai_context:new(), #{<<"run_pid">> => Run}),
    {ok, _} = call(<<"run_computer_command">>,
                   #{<<"command">> => <<"true">>, <<"operationId">> => <<"op">>}, Ctx),
    ?assert(meck:called(muse_computer, execute,
                        ['_', '_', #{idempotency_key => <<"task:t1:op">>, cancel => [Run], auto_start => true}])),
    {links, Links} = process_info(self(), links),
    ?assert(lists:member(Run, Links)),
    unlink(Run),
    Run ! stop.

validation() ->
    Run = fun(Args) -> call(<<"run_computer_command">>, Args) end,
    ?assertMatch({ok, #{<<"error">> := _}},
                 Run(#{<<"command">> => <<"   ">>, <<"operationId">> => <<"x">>})),
    ?assertMatch({ok, #{<<"error">> := _}}, Run(#{<<"operationId">> => <<"x">>})),
    ?assertMatch({ok, #{<<"error">> := _}},
                 Run(#{<<"command">> => binary:copy(<<"a">>, 16001), <<"operationId">> => <<"x">>})),
    ?assertMatch({ok, #{<<"error">> := _}}, Run(#{<<"command">> => <<"ls">>})),
    ?assertMatch({ok, #{<<"error">> := _}},
                 Run(#{<<"command">> => <<"ls">>, <<"operationId">> => <<>>})),
    ?assertMatch({ok, #{<<"error">> := _}},
                 Run(#{<<"command">> => <<"ls">>, <<"operationId">> => binary:copy(<<"o">>, 121)})),
    ?assertMatch({ok, #{<<"command">> := _}},
                 Run(#{<<"command">> => binary:copy(<<"a">>, 16000),
                       <<"operationId">> => binary:copy(<<"o">>, 120)})),
    ?assertMatch({ok, #{<<"error">> := _}},
                 call(<<"write_computer_file">>,
                      #{<<"path">> => <<"/workspace/a">>, <<"text">> => binary:copy(<<"a">>, 262145)})),
    ?assertMatch({ok, #{<<"error">> := _}}, call(<<"read_computer_file">>, #{<<"path">> => <<>>})),
    ?assertMatch({ok, #{<<"error">> := _}},
                 call(<<"list_computer_files">>, #{<<"path">> => binary:copy(<<"p">>, 2049)})),
    ?assertMatch({ok, #{<<"error">> := _}},
                 call(<<"import_computer_pdf">>,
                      #{<<"path">> => <<"/workspace/a.pdf">>, <<"fileId">> => <<>>})),
    ?assertNot(meck:called(muse_computer, execute, ['_', #{<<"command">> => <<"ls">>}, '_'])),
    ?assertNot(meck:called(muse_computer, write, '_')),
    ?assertNot(meck:called(muse_computer, read, '_')),
    ?assertNot(meck:called(muse_computer, import_pdf, '_')).

files() ->
    P = <<"/workspace/a.pdf">>,
    ?assertEqual({ok, with_id(#{<<"path">> => P, <<"entries">> => []})},
                 call(<<"list_computer_files">>, #{<<"path">> => P})),
    ?assertEqual({ok, with_id(#{<<"path">> => P, <<"text">> => <<"hi">>})},
                 call(<<"read_computer_file">>, #{<<"path">> => P})),
    {ok, _} = call(<<"write_computer_file">>, #{<<"path">> => P, <<"text">> => <<>>}),
    ?assert(meck:called(muse_computer, write, [?REF, P, <<>>])),
    {ok, _} = call(<<"mkdir_computer">>, #{<<"path">> => P}),
    ?assert(meck:called(muse_computer, mkdir, [?REF, P])),
    {ok, _} = call(<<"import_computer_pdf">>, #{<<"path">> => P, <<"fileId">> => <<"f-1">>}),
    ?assert(meck:called(muse_computer, import_pdf, [?REF, P, <<"f-1">>])),
    ?assertEqual({ok, with_id(#{<<"id">> => <<"art-1">>})},
                 call(<<"export_computer_pdf">>, #{<<"path">> => P})),
    ?assert(meck:called(muse_computer, export_pdf, [?REF, P])).

before() ->
    Self = self(),
    Order = fun() -> Self ! before, ok end,
    {ok, _} = call_in(spec(<<"computer_status">>, tools(<<"task:t">>, Order)), #{},
                      beamai_context:new()),
    ?assertEqual(before, receive before -> before after 0 -> none end),
    Msg = <<"Task is waiting or finished; do not perform more actions">>,
    Waiting = tools(<<"task:t">>, fun() -> throw({task_failed, Msg}) end),
    [?assertEqual(err(Msg), call_in(S, args(N), beamai_context:new()))
     || #{name := N} = S <- Waiting],
    Lost = tools(<<"task:t">>, fun() -> throw({lost_lease, <<"t">>}) end),
    ?assertEqual(err(<<"Task was paused, cancelled or taken over by another worker">>),
                 call_in(spec(<<"start_computer">>, Lost), #{}, beamai_context:new())),
    Crash = tools(<<"task:t">>, fun() -> error(boom) end),
    ?assertMatch({ok, #{<<"error">> := _}},
                 call_in(spec(<<"stop_computer">>, Crash), #{}, beamai_context:new())),
    ?assertNot(meck:called(muse_computer, start, '_')),
    ?assertNot(meck:called(muse_computer, stop, '_')),
    ?assertNot(meck:called(muse_computer, execute, '_')),
    ?assertNot(meck:called(muse_computer, export_pdf, '_')).

args(<<"run_computer_command">>) -> #{<<"command">> => <<"ls">>, <<"operationId">> => <<"o">>};
args(<<"write_computer_file">>) -> #{<<"path">> => <<"/workspace/a">>, <<"text">> => <<"t">>};
args(<<"import_computer_pdf">>) -> #{<<"path">> => <<"/workspace/a">>, <<"fileId">> => <<"f">>};
args(<<"computer_status">>) -> #{};
args(<<"start_computer">>) -> #{};
args(<<"stop_computer">>) -> #{};
args(_) -> #{<<"path">> => <<"/workspace/a">>}.

errors() ->
    Conflict = <<"This operation ID already belongs to a different command">>,
    meck:expect(muse_computer, execute, fun(_, _, _) -> {error, {409, Conflict}} end),
    ?assertEqual(err(Conflict), call(<<"run_computer_command">>, args(<<"run_computer_command">>))),
    meck:expect(muse_computer, read, fun(_, _) -> {error, {422, <<"Choose an absolute path inside /workspace">>}} end),
    ?assertEqual(err(<<"Choose an absolute path inside /workspace">>),
                 call(<<"read_computer_file">>, #{<<"path">> => <<"/etc/passwd">>})),
    meck:expect(muse_computer, start, fun(_) -> error(badarg) end),
    ?assertEqual(err(?FAILED), call(<<"start_computer">>, #{})),
    meck:expect(muse_computer, snapshot, fun(_) -> exit(down) end),
    ?assertEqual(err(?FAILED), call(<<"computer_status">>, #{})),
    meck:expect(muse_computer, list, fun(_, _) -> throw(oops) end),
    ?assertEqual(err(?FAILED), call(<<"list_computer_files">>, #{<<"path">> => <<"/workspace">>})),
    meck:expect(muse_computer, mkdir, fun(_, _) -> {error, weird} end),
    ?assertEqual(err(?FAILED), call(<<"mkdir_computer">>, #{<<"path">> => <<"/workspace/d">>})).

%% Instructions: sha256 of the Docker string evaluated from
%% computer-tools.ts under Node 24.

instructions_test_() ->
    Docker = muse_computer_tools:instructions(light),
    [?_assertEqual(1059, byte_size(Docker)),
     ?_assertEqual(<<"3a5048b9bc785d039be2596c4c93e4cca40d771fac7f2e939554e8a6b48dc931">>,
                   muse_ids:sha256hex(Docker)),
     ?_assertMatch(<<"The computer is a single-owner Docker Linux container", _/binary>>, Docker)].

network(Value, Extra) ->
    {ok, C} = muse_config:from_env(Extra#{<<"COMPUTER_NETWORK">> => Value}),
    muse_config:set(C).

%% COMPUTER_NETWORK picks the light text (OpenMuse's verbatim with `none`),
%% then the pool note (not in OpenMuse) follows.
network_instructions_test_() ->
    {foreach, fun() -> ok end, fun(_) -> persistent_term:erase({muse_config, config}) end,
     [{"none: OpenMuse's text and the pool note",
       fun() ->
               network(<<"none">>, #{<<"COMPUTER_IDLE_MINUTES">> => <<"20">>}),
               Light = muse_computer_tools:instructions(light),
               I = muse_computer_tools:instructions(),
               ?assertMatch(<<Light:(byte_size(Light))/binary, " Each conversation and each background task "
                              "has its own computer", _/binary>>, I),
               ?assertNotEqual(nomatch, binary:match(I, <<"start_computer is optional">>)),
               ?assertNotEqual(nomatch, binary:match(I, <<"after 20 minutes unused">>))
       end},
      {"bridge: the networked text",
       fun() ->
               network(<<"bridge">>, #{}),
               I = muse_computer_tools:instructions(),
               Has = fun(P) -> binary:match(I, P) =/= nomatch end,
               ?assertMatch(<<"The computer is a single-owner Docker Linux container", _/binary>>, I),
               ?assert(Has(<<"It can reach the internet">>)),
               ?assert(Has(<<"no web browser">>)),
               ?assert(Has(<<"no API credentials">>)),
               ?assert(Has(<<"curl is not installed">>)),
               ?assertNot(Has(<<"Network access is disabled">>)),
               ?assert(Has(<<"start_computer is optional">>)),
               ?assertEqual(muse_computer_tools:instructions(light_network),
                            binary:part(I, 0, byte_size(muse_computer_tools:instructions(light_network))))
       end},
      {"desktop with bridge: online desktop text",
       fun() ->
               network(<<"bridge">>, #{<<"COMPUTER_DESKTOP">> => <<"true">>}),
               I = muse_computer_tools:instructions(),
               Has = fun(P) -> binary:match(I, P) =/= nomatch end,
               ?assert(Has(<<"It can reach the internet from commands">>)),
               ?assert(Has(<<"no web browser in it">>)),
               ?assertNot(Has(<<"Network access is disabled">>)),
               ?assertNot(Has(<<"offline apps">>)),
               ?assert(Has(<<"use_desktop">>))
       end},
      {"start_computer description follows the network",
       fun() ->
               network(<<"none">>, #{}),
               meck:new(muse_computer, [passthrough]),
               try
                   #{description := D} = spec(<<"start_computer">>),
                   ?assertEqual(<<"Start the configured private Linux computer with networking disabled">>, D)
               after
                   meck:unload(muse_computer)
               end
       end}]}.

%% The desktop variant (COMPUTER_DESKTOP=true; not in OpenMuse): use_desktop
%% between import_computer_pdf and export_computer_pdf, its own
%% instructions, 16 chat steps.

desktop(Flag) ->
    {ok, C} = muse_config:from_env(#{<<"COMPUTER_DESKTOP">> => atom_to_binary(Flag),
                                     <<"COMPUTER_NETWORK">> => <<"none">>}),
    muse_config:set(C).

with_desktop(Tests) ->
    {foreach,
     fun() ->
             setup(<<"docker">>),
             desktop(true),
             meck:new(muse_computer_desktop, [passthrough]),
             meck:new(muse_signing, [passthrough]),
             meck:expect(muse_signing, signed_path,
                         fun(O, P) -> <<P/binary, "?owner=", O/binary, "&expires=1&signature=s">> end)
     end,
     fun(X) ->
             meck:unload(muse_signing),
             meck:unload(muse_computer_desktop),
             persistent_term:erase({muse_config, config}),
             cleanup(X)
     end,
     Tests}.

-define(SHOT(Status, Data, Warning),
        {ok, #{receipt => #{<<"id">> => <<"r-1">>, <<"command">> => <<"desktop left_click (1, 2)">>,
                            <<"status">> => Status},
               width => 1280, height => 800, image => base64:decode(Data), mime_type => <<"image/jpeg">>,
               data => Data, uncertain => Status =:= <<"interrupted">>, warning => Warning}}).

desktop_tools_test_() ->
    with_desktop(
      [{"use_desktop sits between import and export",
        fun() ->
                Names = [N || #{name := N} <- tools()],
                ?assertEqual(lists:sublist(?NAMES, 9) ++ [<<"use_desktop">>, <<"export_computer_pdf">>],
                             Names)
        end},
       {"use_desktop description and parameters", fun desktop_spec/0},
       {"use_desktop returns text plus the screenshot as an image part", fun desktop_call/0},
       {"use_desktop validation and errors", fun desktop_errors/0},
       {"other descriptions are unchanged", fun docker_descriptions_with_desktop/0}]).

desktop_spec() ->
    #{description := D, parameters := P} = spec(<<"use_desktop">>),
    ?assertEqual(<<"See and operate the computer's graphical desktop. Actions: screenshot, left_click, "
                   "double_click, right_click, mouse_move, type, key, scroll, wait. Coordinates are "
                   "[x, y] pixels in the 1280x800 screenshot. Every action returns a new screenshot. "
                   "A stopped computer is started first.">>, D),
    ?assertEqual(nomatch, binary:match(D, [<<"internet">>, <<"network">>, <<"browser">>])),
    ?assertEqual(lists:sort([<<"action">>, <<"coordinate">>, <<"text">>, <<"scroll_direction">>,
                             <<"scroll_amount">>, <<"duration">>, <<"operationId">>]),
                 lists:sort(maps:keys(P))),
    ?assertMatch(#{required := true}, maps:get(<<"operationId">>, P)),
    ?assertMatch(#{required := true}, maps:get(<<"action">>, P)),
    ?assertMatch(#{required := false}, maps:get(<<"coordinate">>, P)).

desktop_call() ->
    Jpeg = base64:encode(<<255, 216, 255, 0>>),
    meck:expect(muse_computer_desktop, desktop_action,
                fun(_, _, _) -> ?SHOT(<<"succeeded">>, Jpeg, undefined) end),
    {ok, {parts, [#{type := text, text := Text},
                  #{type := image, source := #{type := base64, media_type := <<"image/jpeg">>, data := Jpeg}}]}} =
        call(<<"use_desktop">>, #{<<"action">> => <<"left_click">>, <<"coordinate">> => [1, 2],
                                  <<"operationId">> => <<"op-7">>}),
    ?assertEqual({ok, #{<<"status">> => <<"succeeded">>, <<"action">> => <<"desktop left_click (1, 2)">>,
                        <<"receiptId">> => <<"r-1">>, <<"computerId">> => <<"pc-task:t1">>,
                        <<"screen">> => #{<<"width">> => 1280, <<"height">> => 800},
                        <<"screenshot">> => <<"attached as an image for this step only">>,
                        <<"screenshotUrl">> => <<"/api/computer/desktop/screenshot?owner=owner-1&expires=1"
                                                 "&signature=s&computer=pc-task:t1&receipt=r-1">>}},
                 muse_json:decode(Text)),
    %% history keeps only the text view
    ?assertEqual(Text, beamai_tool:result_text({parts, [#{type => text, text => Text}, #{type => image}]})),
    ?assert(meck:called(muse_computer_desktop, desktop_action,
                        [?REF, #{<<"action">> => <<"left_click">>, <<"coordinate">> => [1, 2]},
                         #{idempotency_key => <<"task:t1:op-7">>, auto_start => true}])),
    meck:expect(muse_computer_desktop, desktop_action,
                fun(_, _, _) -> ?SHOT(<<"interrupted">>, <<>>, <<"uncertain">>) end),
    ?assertMatch({ok, #{<<"screenshot">> := <<"unavailable">>, <<"warning">> := <<"uncertain">>,
                        <<"status">> := <<"interrupted">>}},
                 call(<<"use_desktop">>, #{<<"action">> => <<"screenshot">>, <<"operationId">> => <<"o">>})).

desktop_errors() ->
    meck:expect(muse_computer_desktop, desktop_action,
                fun(_, _, _) -> {error, {409, <<"Start the computer before using its terminal or files">>}} end),
    ?assertEqual(err(<<"Start the computer before using its terminal or files">>),
                 call(<<"use_desktop">>, #{<<"action">> => <<"screenshot">>, <<"operationId">> => <<"o">>})),
    %% the tool schema refuses before the service is called
    meck:reset(muse_computer_desktop),
    ?assertMatch({ok, #{<<"error">> := _}},
                 call(<<"use_desktop">>, #{<<"action">> => <<"screenshot">>})),
    ?assertMatch({ok, #{<<"error">> := _}},
                 call(<<"use_desktop">>, #{<<"action">> => <<"key">>, <<"text">> => <<"a;b">>,
                                           <<"operationId">> => <<"o">>})),
    ?assertNot(meck:called(muse_computer_desktop, desktop_action, '_')).

docker_descriptions_with_desktop() ->
    Ds = [D || #{name := N, description := D} <- tools(), N =/= <<"use_desktop">>],
    ?assertEqual(10, length(Ds)),
    ?assertEqual(<<"Start the configured private Linux computer with networking disabled">>,
                 lists:nth(2, Ds)).

no_desktop_tool_test_() ->
    {setup,
     fun() -> setup(<<"docker">>), desktop(false) end,
     fun(X) -> persistent_term:erase({muse_config, config}), cleanup(X) end,
     [?_assertEqual(?NAMES, [N || #{name := N} <- tools()]),
      %% CHAT_MAX_STEPS (default 200), with or without the desktop
      ?_assertEqual(200, muse_chat_agent:max_steps()),
      ?_assertMatch(<<"The computer is a single-owner Docker Linux container with bash", _/binary>>,
                    muse_computer_tools:instructions())]}.

desktop_instructions_test_() ->
    {setup,
     fun() -> desktop(true) end,
     fun(_) -> persistent_term:erase({muse_config, config}) end,
     fun(_) ->
             D = muse_computer_tools:instructions(),
             Has = fun(P) -> binary:match(D, P) =/= nomatch end,
             [?_assertEqual(muse_computer_tools:instructions(desktop),
                            binary:part(D, 0, byte_size(muse_computer_tools:instructions(desktop)))),
              ?_assertEqual(200, muse_chat_agent:max_steps()),
              ?_assertMatch(<<"The computer is a single-owner Docker Linux container with a graphical "
                              "desktop", _/binary>>, D),
              [?_assert(Has(P)) || P <- [<<"Network access is disabled">>, <<"xterm">>, <<"LibreOffice">>,
                                         <<"mupdf">>, <<"DISPLAY set">>, <<"use_desktop">>,
                                         <<"operationId">>, <<"1280x800">>, <<"import_computer_pdf">>,
                                         <<"never automatically retry">>,
                                         <<"Look at a screenshot before acting">>,
                                         <<"Describe only what a screenshot actually shows">>]],
              [?_assertNot(Has(P)) || P <- [<<"Firefox">>, <<"firefox">>, <<"Chrome">>, <<"internet is reachable">>,
                                            <<"Outbound network access is enabled">>, <<"publicly reachable">>,
                                            <<"listening ports">>, <<"Xfce">>, <<"E2B">>,
                                            <<"cannot view">>]]]
     end}.

%% A busy computer (shared by a conversation and its tasks) is waited for,
%% up to `computer_busy_wait_ms`, then the busy error is returned.
busy_wait_test_() ->
    Busy = {error, {409, <<"Computer is busy. Wait for the current operation to finish.">>}},
    {foreach,
     fun() -> setup(docker), application:set_env(muse_agent, computer_busy_wait_ms, 2500) end,
     fun(X) -> application:unset_env(muse_agent, computer_busy_wait_ms), cleanup(X) end,
     [fun() ->
              Left = counters:new(1, []),
              counters:put(Left, 1, 2),
              meck:expect(muse_computer, execute,
                          fun(_, Args, _) ->
                                  case counters:get(Left, 1) of
                                      0 -> {ok, Args#{<<"status">> => <<"succeeded">>}};
                                      _ -> counters:sub(Left, 1, 1), Busy
                                  end
                          end),
              ?assertMatch({ok, #{<<"status">> := <<"succeeded">>}},
                           call(<<"run_computer_command">>, #{<<"command">> => <<"ls">>,
                                                              <<"operationId">> => <<"op-1">>})),
              ?assertEqual(3, meck:num_calls(muse_computer, execute, '_'))
      end,
      fun() ->
              meck:expect(muse_computer, read, fun(_, _) -> Busy end),
              T0 = erlang:monotonic_time(millisecond),
              ?assertEqual(err(<<"Computer is busy. Wait for the current operation to finish.">>),
                           call(<<"read_computer_file">>, #{<<"path">> => <<"/workspace/a">>})),
              ?assert(erlang:monotonic_time(millisecond) - T0 >= 2000)
      end]}.
