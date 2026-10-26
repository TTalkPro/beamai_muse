%% @doc A chat reply's products (M9-11, not in OpenMuse): the files a reply
%% made, kept in Files and shown under the reply as one "全部文件" card
%% (muse_ui_products).
%%
%% What counts. Only what the reply created or changed:
%% - files under the conversation's computer `/workspace` (scope
%%   `thread:<threadId>`) whose mtime is at or after the reply's start minus
%%   2 s (`muse_computer:changed_since/3`, files.py: regular files, no
%%   symlinks, no hidden entries, no `node_modules`, `__pycache__`, `venv`,
%%   `site-packages`, `*.pyc`; at most 50 files, 8 levels, each at most
%%   min(10 MB, FILES_MAX_MB), all together at most 4 × FILES_MAX_MB). The
%%   computer is looked at only when the reply used a tool that can change
%%   its files (`run_computer_command`, `write_computer_file`,
%%   `use_desktop`, `import_computer_pdf`), and never started for it;
%% - the paths `write_computer_file` wrote in the reply (a scan finds them
%%   too; listed once);
%% - files `export_computer_pdf` put into Files during the reply, as they
%%   are (the computer copy of an exported path is not stored again).
%% A PDF that `import_computer_pdf` copied in and that is still the same
%% bytes is an input, not a product, and is left out.
%%
%% How it is seen. `observe/2` sits in the chat run's AG-UI event
%% transform (muse_chat_agent): it runs in the run's own process, so the
%% reply's facts (start time, tool names, written paths, exported ids) are
%% kept in that process's dictionary from RUN_STARTED on. At RUN_FINISHED
%% (or RUN_ERROR; a stopped reply finishes with a cancelled RUN_FINISHED)
%% it collects and stores the products before the event goes out, and puts
%% a `CUSTOM` event `muse.products` (the turn record) in front of it. So
%% when muse_chat_relay re-renders the log at the end of the run, the card
%% is already there; a reload renders it from the same record.
%%
%% Storage. Every product is copied into Files (muse_files:upload/4, any
%% type) under 「对话产物」/<conversation title> (created on demand; the
%% conversation's folder is found again by its `threadId`, so renaming or
%% moving it is fine, and two conversations with one title get "名字 (2)").
%% The file record keeps its provenance: `threadId`, `runId`,
%% `computerPath`, `computerId`, `sha256`. A path produced again in a later
%% reply with other bytes becomes a new file, a new version (`version`
%% N + 1, `previousId`): each reply's card keeps showing exactly what that
%% reply made. With the same bytes the earlier file is reused. Products
%% live in Files, so they stay when the computer stops or is deleted.
%%
%% The reply's list is a `chat-products` record per conversation (id = the
%% thread id): `{id, threadId, turns: [{runId, anchor, files, createdAt}]}`,
%% `files` being `{id, name, size, kind, mimeType, path}`. `anchor` is the
%% number of chat log messages when the reply ended; the card goes after
%% the reply's last text at or before it. Deleting the conversation
%% deletes the record (the files stay in Files).
%%
%% `zip/3` packs a reply's files ("全部下载") in memory, at most
%% 4 × FILES_MAX_MB, entry names being the files' base names, deduplicated
%% (`a.txt`, `a (2).txt`).
-module(muse_chat_products).

-export([observe/2, collect/4, turns/2, turn/3, files/3, zip/3, zip_name/2, zip_limit/0,
         delete_thread/2, entry_names/1, prompt/0]).

-define(KIND, <<"chat-products">>).
-define(PD, {?MODULE, run}).
-define(ROOT, <<"对话产物"/utf8>>).
-define(MAX_FILES, 50).
-define(DEPTH, 8).
-define(MARGIN_MS, 2000).
%% files.py `read_file`
-define(READ_LIMIT, 10485760).
-define(BUSY_WAIT_MS, 30000).
%% tools that can change the computer's files
-define(CHANGING, [<<"run_computer_command">>, <<"write_computer_file">>, <<"use_desktop">>,
                   <<"import_computer_pdf">>]).

-type owner() :: binary().
-type turn() :: #{binary() => term()}.
-type facts() :: #{since := integer(), computer := boolean(), written := [binary()],
                   exported := [binary()], imported := #{binary() => binary()}}.
-export_type([turn/0, facts/0]).

%%%===================================================================
%%% Watching a run
%%%===================================================================

%% @doc The event transform step: returns the events to emit instead of
%% `Event` (at the run's end, `muse.products` first when the reply made
%% files). Never fails the run: a failed collection is logged.
-spec observe(owner(), map()) -> [map()].
observe(_Owner, #{<<"type">> := <<"RUN_STARTED">>, <<"threadId">> := Tid, <<"runId">> := Run} = Event) ->
    put(?PD, #{thread => Tid, run => Run, since => muse_time:now_ms(), calls => #{},
               computer => false, written => [], exported => [], imported => #{}}),
    [Event];
observe(_Owner, #{<<"type">> := <<"TOOL_CALL_START">>, <<"toolCallId">> := Id, <<"toolCallName">> := Name} = Event) ->
    update(fun(#{calls := Calls, computer := Used} = S) ->
                   S#{calls => Calls#{Id => {Name, <<>>}}, computer => Used orelse lists:member(Name, ?CHANGING)}
           end),
    [Event];
observe(_Owner, #{<<"type">> := <<"TOOL_CALL_ARGS">>, <<"toolCallId">> := Id, <<"delta">> := Delta} = Event)
  when is_binary(Delta) ->
    update(fun(#{calls := Calls} = S) ->
                   case maps:find(Id, Calls) of
                       {ok, {Name, Args}} -> S#{calls => Calls#{Id => {Name, <<Args/binary, Delta/binary>>}}};
                       error -> S
                   end
           end),
    [Event];
observe(_Owner, #{<<"type">> := <<"TOOL_CALL_RESULT">>, <<"toolCallId">> := Id, <<"content">> := Content} = Event) ->
    update(fun(#{calls := Calls} = S) ->
                   case maps:find(Id, Calls) of
                       {ok, {Name, Args}} -> note_result(Name, decode(Args), decode(Content), S);
                       error -> S
                   end
           end),
    [Event];
observe(Owner, #{<<"type">> := Type} = Event) when Type =:= <<"RUN_FINISHED">>; Type =:= <<"RUN_ERROR">> ->
    case erase(?PD) of
        #{thread := Tid, run := Run} = S ->
            try collect(Owner, Tid, Run, maps:with([since, computer, written, exported, imported], S)) of
                {ok, #{<<"files">> := [_ | _]} = Turn} ->
                    [beamai_agui_event:custom(<<"muse.products">>, Turn), Event];
                _ ->
                    [Event]
            catch
                Class:Reason ->
                    logger:warning("chat products ~ts: ~p", [Tid, {Class, Reason}]),
                    [Event]
            end;
        _ ->
            [Event]
    end;
observe(_Owner, Event) ->
    [Event].

update(Fun) ->
    case get(?PD) of
        #{} = S -> put(?PD, Fun(S));
        _ -> undefined
    end.

decode(Json) when is_binary(Json) ->
    case muse_json:decode(Json) of
        {ok, #{} = Map} -> Map;
        _ -> #{}
    end;
decode(_) ->
    #{}.

note_result(<<"write_computer_file">>, _Args, #{<<"path">> := Path}, #{written := W} = S) when is_binary(Path) ->
    S#{written => W ++ [Path]};
note_result(<<"export_computer_pdf">>, _Args, #{<<"id">> := Id}, #{exported := E} = S) when is_binary(Id) ->
    S#{exported => E ++ [Id]};
note_result(<<"import_computer_pdf">>, #{<<"fileId">> := FileId}, #{<<"path">> := Path}, #{imported := I} = S)
  when is_binary(FileId), is_binary(Path) ->
    S#{imported => I#{Path => FileId}};
note_result(_Name, _Args, _Result, S) ->
    S.

%%%===================================================================
%%% Collecting
%%%===================================================================

%% @doc Find, store and record the products of run `Run` of conversation
%% `Tid` (see the module doc). Returns the turn record; its `files` is
%% empty (and nothing is stored) when the reply made no files.
-spec collect(owner(), binary(), binary(), facts()) -> {ok, turn()}.
collect(Owner, Tid, Run, Facts) ->
    Exported = exported(Owner, maps:get(exported, Facts, [])),
    ExportedPaths = [P || #{<<"source">> := <<"Computer: ", P/binary>>} <- Exported],
    Ref = muse_computer:ref(Owner, <<"thread:", Tid/binary>>),
    Scanned = case maps:get(computer, Facts, false) of
                  true -> scan(Ref, maps:get(since, Facts));
                  false -> []
              end,
    Paths = lists:sublist([P || P <- unique(Scanned ++ maps:get(written, Facts, [])),
                                not lists:member(P, ExportedPaths)], ?MAX_FILES),
    Copied = copy(Owner, Tid, Run, Ref, Paths, maps:get(imported, Facts, #{})),
    Files = unique_by_id(Copied ++ Exported),
    Turn = #{<<"runId">> => Run,
             <<"anchor">> => length(muse_chat_log:messages(Owner, Tid)),
             <<"files">> => [summary(F) || F <- Files],
             <<"createdAt">> => muse_time:now_iso()},
    case Files of
        [] -> ok;
        _ -> save(Owner, Tid, Turn)
    end,
    {ok, Turn}.

exported(Owner, Ids) ->
    lists:append([case muse_files:get(Owner, Id) of
                      {ok, F} -> [F];
                      _ -> []
                  end || Id <- unique(Ids)]).

scan(Ref, Since) ->
    Max = min(?READ_LIMIT, muse_files:max_bytes()),
    case patient(fun() -> muse_computer:changed_since(Ref, Since - ?MARGIN_MS,
                                                      #{limit => ?MAX_FILES, max_bytes => Max, depth => ?DEPTH})
                 end) of
        {ok, #{<<"files">> := Files} = R} ->
            case maps:get(<<"skipped">>, R, []) of
                [] -> ok;
                Skipped -> logger:info("chat products: ~b files too large to keep", [length(Skipped)])
            end,
            [P || #{<<"path">> := P} <- Files, is_binary(P)];
        Other ->
            logger:warning("chat products: workspace scan failed: ~0p", [Other]),
            []
    end.

%% Read each file from the computer and store it, within the total cap.
copy(_Owner, _Tid, _Run, _Ref, [], _Imported) ->
    [];
copy(Owner, Tid, Run, Ref, Paths, Imported) ->
    Previous = previous_versions(Owner, Tid),
    {Stored, _} =
        lists:foldl(
          fun(Path, {Acc, Budget}) ->
                  case patient(fun() -> muse_computer:download(Ref, Path) end) of
                      {ok, #{bytes := Bytes}} when byte_size(Bytes) =< Budget ->
                          case keep(Owner, Tid, Run, Ref, Path, Bytes, Previous, Imported) of
                              {ok, File} -> {[File | Acc], Budget - byte_size(Bytes)};
                              skip -> {Acc, Budget}
                          end;
                      {ok, _} ->
                          logger:info("chat products: ~ts is over the reply's size budget", [Path]),
                          {Acc, Budget};
                      Error ->
                          logger:info("chat products: could not read ~ts: ~0p", [Path, Error]),
                          {Acc, Budget}
                  end
          end, {[], zip_limit()}, Paths),
    lists:reverse(Stored).

keep(Owner, Tid, Run, Ref, Path, Bytes, Previous, Imported) ->
    Sha = muse_ids:sha256hex(Bytes),
    case same_as_import(Owner, maps:get(Path, Imported, undefined), Sha) of
        true ->
            skip;
        false ->
            case maps:get(Path, Previous, undefined) of
                #{<<"sha256">> := Sha} = Same ->
                    {ok, Same};
                Last ->
                    {Version, Prev} = case Last of
                                          #{<<"id">> := LastId} -> {maps:get(<<"version">>, Last, 1) + 1,
                                                                    #{<<"previousId">> => LastId}};
                                          undefined -> {1, #{}}
                                      end,
                    Meta = Prev#{<<"threadId">> => Tid, <<"runId">> => Run, <<"computerPath">> => Path,
                                 <<"computerId">> => muse_computer:computer_id(Ref), <<"sha256">> => Sha,
                                 <<"version">> => Version},
                    maybe
                        {ok, Folder} ?= thread_folder(Owner, Tid),
                        {ok, File} ?= muse_files:upload(Owner, filename:basename(Path), Bytes,
                                                        #{folder => Folder, meta => Meta,
                                                          source => <<"对话产物 · "/utf8, Path/binary>>}),
                        {ok, muse_files:normalize(maps:remove(<<"url">>, File))}
                    else
                        Error ->
                            logger:info("chat products: could not keep ~ts: ~0p", [Path, Error]),
                            skip
                    end
            end
    end.

same_as_import(_Owner, undefined, _Sha) ->
    false;
same_as_import(Owner, FileId, Sha) ->
    case muse_files:bytes(Owner, FileId) of
        {ok, Bin} -> muse_ids:sha256hex(Bin) =:= Sha;
        _ -> false
    end.

%% The latest stored version of each computer path of the conversation.
previous_versions(Owner, Tid) ->
    lists:foldl(fun(#{<<"computerPath">> := P} = F, Acc) ->
                        case maps:find(P, Acc) of
                            {ok, Old} ->
                                case maps:get(<<"version">>, F, 1) > maps:get(<<"version">>, Old, 1) of
                                    true -> Acc#{P => F};
                                    false -> Acc
                                end;
                            error -> Acc#{P => F}
                        end
                end, #{},
                [F || F = #{<<"threadId">> := T, <<"computerPath">> := P} <- muse_files:list(Owner, unsigned),
                      T =:= Tid, is_binary(P)]).

%% Run `Fun` again while a task sharing the computer holds it.
patient(Fun) ->
    patient(Fun, erlang:monotonic_time(millisecond) + ?BUSY_WAIT_MS).

patient(Fun, Deadline) ->
    case Fun() of
        {error, {409, <<"Computer is busy", _/binary>>}} = Busy ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(500), patient(Fun, Deadline);
                false -> Busy
            end;
        Other ->
            Other
    end.

summary(#{<<"id">> := Id} = F) ->
    #{<<"id">> => Id,
      <<"name">> => maps:get(<<"name">>, F, <<>>),
      <<"size">> => maps:get(<<"size">>, F, 0),
      <<"kind">> => atom_to_binary(muse_files:kind(F)),
      <<"mimeType">> => maps:get(<<"mimeType">>, F, <<>>),
      <<"path">> => case F of
                        #{<<"computerPath">> := P} -> P;
                        #{<<"source">> := <<"Computer: ", P/binary>>} -> P;
                        _ -> null
                    end}.

unique(List) ->
    lists:reverse(lists:foldl(fun(X, Acc) ->
                                      case lists:member(X, Acc) of
                                          true -> Acc;
                                          false -> [X | Acc]
                                      end
                              end, [], List)).

unique_by_id(Files) ->
    {Out, _} = lists:foldl(fun(#{<<"id">> := Id} = F, {Acc, Seen}) ->
                                   case maps:is_key(Id, Seen) of
                                       true -> {Acc, Seen};
                                       false -> {[F | Acc], Seen#{Id => true}}
                                   end
                           end, {[], #{}}, Files),
    lists:reverse(Out).

%%%===================================================================
%%% Folders
%%%===================================================================

%% 「对话产物」/<conversation title>, found by `threadId`, made on demand.
thread_folder(Owner, Tid) ->
    maybe
        {ok, Root} ?= root_folder(Owner),
        case [Id || #{<<"id">> := Id, <<"parentId">> := P, <<"threadId">> := T} <- muse_files:folders(Owner),
                    P =:= Root, T =:= Tid] of
            [Id | _] -> {ok, Id};
            [] -> new_folder(Owner, Root, folder_title(Owner, Tid), Tid, 1)
        end
    end.

root_folder(Owner) ->
    Find = fun() ->
                   [Id || #{<<"id">> := Id, <<"parentId">> := null, <<"name">> := N} <- muse_files:folders(Owner),
                          string:lowercase(N) =:= string:lowercase(?ROOT)]
           end,
    case Find() of
        [Id | _] -> {ok, Id};
        [] ->
            case muse_files:create_folder(Owner, ?ROOT, null) of
                {ok, #{<<"id">> := Id}} -> {ok, Id};
                Error ->
                    case Find() of
                        [Id | _] -> {ok, Id};
                        [] -> Error
                    end
            end
    end.

new_folder(_Owner, _Root, _Title, _Tid, N) when N > 50 ->
    {error, {409, <<"No free folder name">>}};
new_folder(Owner, Root, Title, Tid, N) ->
    Name = case N of
               1 -> Title;
               _ -> <<Title/binary, " (", (integer_to_binary(N))/binary, ")">>
           end,
    case muse_files:create_folder(Owner, Name, Root, #{<<"threadId">> => Tid}) of
        {ok, #{<<"id">> := Id}} -> {ok, Id};
        {error, {409, _}} -> new_folder(Owner, Root, Title, Tid, N + 1);
        Error -> Error
    end.

%% The conversation's shown title as a folder name (no slashes, at most 70
%% characters so a " (N)" still fits the 80 of muse_files).
folder_title(Owner, Tid) ->
    Title = title(Owner, Tid),
    Chars = [case C of
                 $/ -> $-;
                 $\\ -> $-;
                 _ -> C
             end || C <- unicode:characters_to_list(Title), C >= 32, C =/= 127],
    case string:trim(lists:sublist(Chars, 70)) of
        [] -> <<"新会话"/utf8>>;
        Clean -> unicode:characters_to_binary(Clean)
    end.

title(Owner, Tid) ->
    case muse_threads:get(Owner, Tid) of
        {ok, #{<<"kind">> := <<"main">>, <<"title">> := <<"Main conversation">>}} -> <<"主会话"/utf8>>;
        {ok, #{<<"title">> := <<"New chat">>}} -> <<"新会话"/utf8>>;
        {ok, #{<<"title">> := T}} when is_binary(T), T =/= <<>> -> T;
        _ -> <<"新会话"/utf8>>
    end.

%%%===================================================================
%%% Records
%%%===================================================================

save(Owner, Tid, #{<<"runId">> := Run} = Turn) ->
    Old = case muse_store:get(Owner, ?KIND, Tid) of
              #{<<"turns">> := Ts} -> [T || T = #{<<"runId">> := R} <- Ts, R =/= Run];
              _ -> []
          end,
    _ = muse_store:put(Owner, ?KIND, #{<<"id">> => Tid, <<"threadId">> => Tid, <<"turns">> => Old ++ [Turn]}),
    ok.

%% @doc The conversation's replies that made files, oldest first.
-spec turns(owner(), binary()) -> [turn()].
turns(Owner, Tid) ->
    case is_binary(Tid) andalso muse_store:get(Owner, ?KIND, Tid) of
        #{<<"turns">> := Turns} -> Turns;
        _ -> []
    end.

-spec turn(owner(), binary(), binary()) -> {ok, turn()} | {error, {404, binary()}}.
turn(Owner, Tid, Run) ->
    case [T || T = #{<<"runId">> := R} <- turns(Owner, Tid), R =:= Run] of
        [T | _] -> {ok, T};
        [] -> {error, {404, <<"These files were not found">>}}
    end.

%% @doc The reply's files as they are in Files now (deleted ones left out).
-spec files(owner(), binary(), binary()) -> {ok, [muse_files:artifact()]} | {error, {404, binary()}}.
files(Owner, Tid, Run) ->
    case turn(Owner, Tid, Run) of
        {ok, #{<<"files">> := Fs}} ->
            {ok, lists:append([case muse_files:get(Owner, Id) of
                                   {ok, F} -> [F];
                                   _ -> []
                               end || #{<<"id">> := Id} <- Fs])};
        Error ->
            Error
    end.

-spec delete_thread(owner(), binary()) -> ok.
delete_thread(Owner, Tid) ->
    muse_store:remove(Owner, ?KIND, Tid).

%%%===================================================================
%%% Zip
%%%===================================================================

%% @doc The most a reply's files may weigh together (and the most "全部下载"
%% packs): 4 × FILES_MAX_MB.
-spec zip_limit() -> pos_integer().
zip_limit() ->
    4 * muse_files:max_bytes().

%% @doc All of a reply's files in one zip, built in memory.
-spec zip(owner(), binary(), binary()) -> {ok, binary(), binary()} | {error, {pos_integer(), binary()}}.
zip(Owner, Tid, Run) ->
    maybe
        {ok, Files} ?= files(Owner, Tid, Run),
        ok ?= case Files of
                  [] -> {error, {404, <<"这些文件已经不在了"/utf8>>}};
                  _ -> ok
              end,
        Total = lists:sum([maps:get(<<"size">>, F, 0) || F <- Files]),
        ok ?= case Total > zip_limit() of
                  true -> {error, {413, <<"这些文件一共超过 "/utf8, (integer_to_binary(zip_limit() div 1048576))/binary,
                                          " MB，无法打包下载，请逐个下载。"/utf8>>}};
                  false -> ok
              end,
        {ok, Entries} ?= entries(Owner, Files),
        case zip:create("files.zip", Entries, [memory]) of
            {ok, {_, Zip}} -> {ok, zip_name(Owner, Tid), Zip};
            {error, _} -> {error, {500, <<"Could not pack the files">>}}
        end
    end.

entries(Owner, Files) ->
    Names = entry_names([maps:get(<<"name">>, F, <<>>) || F <- Files]),
    lists:foldr(fun(_, {error, _} = E) -> E;
                   ({Name, #{<<"id">> := Id}}, {ok, Acc}) ->
                        case muse_files:bytes(Owner, Id) of
                            {ok, Bin} -> {ok, [{unicode:characters_to_list(Name), Bin} | Acc]};
                            Error -> Error
                        end
                end, {ok, []}, lists:zip(Names, Files)).

%% @doc Zip entry names: base names only (no directories, no `..`, never
%% absolute), unique ignoring case: `a.txt`, `a (2).txt`.
-spec entry_names([binary()]) -> [binary()].
entry_names(Names) ->
    {Out, _} = lists:foldl(fun(Name, {Acc, Seen}) ->
                                   N = unique_name(safe_name(Name), Seen, 1),
                                   {[N | Acc], Seen#{string:lowercase(N) => true}}
                           end, {[], #{}}, Names),
    lists:reverse(Out).

safe_name(Name) ->
    case muse_files:sanitize_file_name(Name) of
        N when N =:= <<".">>; N =:= <<"..">>; N =:= <<>> -> <<"file">>;
        N -> N
    end.

unique_name(Name, Seen, N) ->
    Candidate = case N of
                    1 -> Name;
                    _ ->
                        Ext = filename:extension(Name),
                        Base = binary:part(Name, 0, byte_size(Name) - byte_size(Ext)),
                        <<Base/binary, " (", (integer_to_binary(N))/binary, ")", Ext/binary>>
                end,
    case maps:is_key(string:lowercase(Candidate), Seen) of
        true -> unique_name(Name, Seen, N + 1);
        false -> Candidate
    end.

%% @doc `<conversation title>-文件.zip`.
-spec zip_name(owner(), binary()) -> binary().
zip_name(Owner, Tid) ->
    <<(folder_title(Owner, Tid))/binary, "-文件.zip"/utf8>>.

%%%===================================================================
%%% Prompt
%%%===================================================================

%% @doc The chat prompt's sentence about products (after OpenMuse's texts).
-spec prompt() -> binary().
prompt() ->
    <<" Files you create or change in the computer's /workspace during a reply are shown to the person at the end "
      "of your reply as downloadable files they can preview, so you need not paste whole file contents into the "
      "chat; name the files instead.">>.
