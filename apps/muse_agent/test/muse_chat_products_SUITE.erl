%% A chat reply's products (M9-11): collection from the conversation's
%% computer (muse_computer mocked: no Docker), storage in Files with
%% provenance, versions, the turn records, the run's event, the zip.
-module(muse_chat_products_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(O, <<"local-user">>).
-define(P, muse_chat_products).

all() ->
    [changed_files_are_kept, caps_hold, only_when_the_computer_was_used, exports_are_included,
     imported_inputs_are_left_out, new_bytes_make_a_new_version, folders_per_conversation,
     a_turn_emits_the_products, a_reply_without_files_has_none, zip_round_trip, zip_names,
     zip_size_cap, zip_owner_check, deleting_the_conversation, prompt_mentions_products].

init_per_testcase(Case, Config) ->
    Extra = case Case of
                caps_hold -> #{<<"FILES_MAX_MB">> => <<"1">>};
                zip_size_cap -> #{<<"FILES_MAX_MB">> => <<"1">>};
                _ -> #{}
            end,
    Env = muse_agent_test_env:start(Extra#{<<"AGENT_BACKEND">> => <<"model">>}),
    ok = muse_workspace:ensure_sample(?O),
    ok = meck:new(muse_computer, [passthrough]),
    ok = meck:expect(muse_computer, ref, fun(O, S) -> {O, <<"pc-", S/binary>>} end),
    ok = meck:expect(muse_computer, ensure, fun(O, S) -> {O, <<"pc-", S/binary>>} end),
    ok = meck:expect(muse_computer, ensure_running, fun(_) -> ok end),
    workspace(#{}),
    [{env, Env} | Config].

end_per_testcase(_Case, Config) ->
    meck:unload(muse_computer),
    muse_agent_test_env:stop(?config(env, Config)).

%% A fake /workspace: path -> bytes, every file "changed".
workspace(Files) ->
    ok = meck:expect(muse_computer, changed_since,
                     fun(_Ref, _Since, _Opts) ->
                             {ok, #{<<"path">> => <<"/workspace">>, <<"truncated">> => false, <<"skipped">> => [],
                                    <<"files">> => [#{<<"path">> => P, <<"size">> => byte_size(B), <<"mtime">> => 1}
                                                    || {P, B} <- lists:sort(maps:to_list(Files))]}}
                     end),
    ok = meck:expect(muse_computer, download,
                     fun(_Ref, P) ->
                             case maps:find(P, Files) of
                                 {ok, B} -> {ok, #{name => filename:basename(P), bytes => B}};
                                 error -> {error, {422, <<"Computer file operation failed">>}}
                             end
                     end),
    ok = meck:expect(muse_computer, write, fun(_, P, _) -> {ok, #{<<"path">> => P}} end).

facts(Extra) ->
    maps:merge(#{since => muse_time:now_ms(), computer => true, written => [], exported => [], imported => #{}},
               Extra).

thread(Title) ->
    Tid = muse_ids:uuid(),
    {ok, _} = muse_threads:create(?O, Tid, Title),
    Tid.

ids(#{<<"files">> := Fs}) -> [Id || #{<<"id">> := Id} <- Fs].

file(Id) ->
    {ok, F} = muse_files:get(?O, Id),
    F.

%% Cases

changed_files_are_kept(_) ->
    Tid = thread(<<"Word counts">>),
    workspace(#{<<"/workspace/count.py">> => <<"print(1)\n">>, <<"/workspace/out/chart.png">> => png()}),
    {ok, Turn} = ?P:collect(?O, Tid, <<"run-1">>,
                            facts(#{written => [<<"/workspace/count.py">>, <<"/workspace/.notes">>]})),
    %% the scan's files and the written ones, once each (the hidden written
    %% file could not be read here, so it is not kept)
    #{<<"files">> := [#{<<"name">> := <<"count.py">>, <<"path">> := <<"/workspace/count.py">>, <<"kind">> := <<"text">>},
                      #{<<"name">> := <<"chart.png">>, <<"kind">> := <<"image">>, <<"size">> := _}],
      <<"runId">> := <<"run-1">>, <<"anchor">> := 0} = Turn,
    %% the scan asked for at most 50 files, 8 levels, min(10 MB, FILES_MAX_MB)
    [{_, {muse_computer, changed_since, [{?O, <<"pc-thread:", Tid/binary>>}, Since, Opts]}, _}] =
        [C || C = {_, {muse_computer, changed_since, _}, _} <- meck:history(muse_computer)],
    ?assert(Since < muse_time:now_ms()),
    ?assertEqual(#{limit => 50, max_bytes => 10485760, depth => 8}, Opts),
    %% stored in 对话产物 / <title>, with provenance
    [Py, Png] = [file(Id) || Id <- ids(Turn)],
    #{<<"threadId">> := Tid, <<"runId">> := <<"run-1">>, <<"computerPath">> := <<"/workspace/count.py">>,
      <<"computerId">> := <<"pc-thread:", Tid/binary>>, <<"version">> := 1, <<"sha256">> := _,
      <<"folderId">> := Folder, <<"mimeType">> := <<"text/plain">>} = Py,
    #{<<"folderId">> := Folder, <<"mimeType">> := <<"image/png">>} = Png,
    ?assertEqual({ok, <<"print(1)\n">>}, muse_files:bytes(?O, maps:get(<<"id">>, Py))),
    ?assertEqual([<<"对话产物"/utf8>>, <<"Word counts">>],
                 [N || #{<<"name">> := N} <- muse_files:folder_path(?O, Folder)]),
    %% the conversation's record
    ?assertEqual([Turn], ?P:turns(?O, Tid)),
    {ok, [_, _]} = ?P:files(?O, Tid, <<"run-1">>),
    %% the products outlive the computer
    ok = meck:expect(muse_computer, download, fun(_, _) -> {error, {404, <<"gone">>}} end),
    {ok, [_, _]} = ?P:files(?O, Tid, <<"run-1">>).

caps_hold(_) ->
    %% FILES_MAX_MB=1: each file at most 1 MB, a reply at most 4 MB
    Tid = thread(<<"Caps">>),
    Big = binary:copy(<<"a">>, 900 * 1024),
    workspace(maps:from_list([{<<"/workspace/f", (integer_to_binary(I))/binary, ".txt">>, Big} || I <- lists:seq(1, 6)])),
    {ok, Turn} = ?P:collect(?O, Tid, <<"run-1">>, facts(#{})),
    ?assertEqual(4, length(ids(Turn))),
    [{_, {_, changed_since, [_, _, #{max_bytes := 1048576}]}, _}] =
        [C || C = {_, {_, changed_since, _}, _} <- meck:history(muse_computer)],
    %% at most 50 files
    Tid2 = thread(<<"Many">>),
    workspace(maps:from_list([{<<"/workspace/n", (integer_to_binary(I))/binary, ".txt">>, integer_to_binary(I)}
                              || I <- lists:seq(1, 60)])),
    {ok, Many} = ?P:collect(?O, Tid2, <<"run-1">>, facts(#{})),
    ?assertEqual(50, length(ids(Many))).

only_when_the_computer_was_used(_) ->
    Tid = thread(<<"Chat only">>),
    workspace(#{<<"/workspace/old.txt">> => <<"old">>}),
    {ok, #{<<"files">> := []}} = ?P:collect(?O, Tid, <<"run-1">>, facts(#{computer => false})),
    ?assertEqual(0, meck:num_calls(muse_computer, changed_since, '_')),
    ?assertEqual(0, meck:num_calls(muse_computer, download, '_')),
    ?assertEqual([], ?P:turns(?O, Tid)),
    %% no folder was made either
    ?assertEqual([], [F || F = #{<<"name">> := <<"对话产物"/utf8>>} <- muse_files:folders(?O)]),
    %% a scan that fails (stopped computer, older image) keeps nothing
    ok = meck:expect(muse_computer, changed_since, fun(_, _, _) -> {error, {409, <<"Computer is not running">>}} end),
    {ok, #{<<"files">> := []}} = ?P:collect(?O, Tid, <<"run-2">>, facts(#{})).

exports_are_included(_) ->
    Tid = thread(<<"Report">>),
    {ok, Pdf} = muse_files:pdf_bytes(?O, sample_id()),
    {ok, #{<<"id">> := Exported}} = muse_files:import(?O, <<"report.pdf">>, Pdf, <<"Computer: /workspace/report.pdf">>),
    workspace(#{<<"/workspace/report.pdf">> => Pdf, <<"/workspace/notes.md">> => <<"# Notes\n">>}),
    {ok, Turn} = ?P:collect(?O, Tid, <<"run-1">>, facts(#{exported => [Exported, Exported]})),
    %% the exported file as it is, the computer copy of its path not again
    [Notes, Exported] = ids(Turn),
    ?assertMatch(#{<<"name">> := <<"notes.md">>, <<"mimeType">> := <<"text/markdown">>}, file(Notes)),
    [#{<<"path">> := <<"/workspace/report.pdf">>, <<"kind">> := <<"pdf">>}] =
        [F || F = #{<<"id">> := I} <- maps:get(<<"files">>, Turn), I =:= Exported],
    ?assertEqual(1, length([F || F = #{<<"name">> := <<"report.pdf">>} <- muse_files:list(?O, unsigned)])).

imported_inputs_are_left_out(_) ->
    Tid = thread(<<"Fill">>),
    Sample = sample_id(),
    {ok, Pdf} = muse_files:pdf_bytes(?O, Sample),
    workspace(#{<<"/workspace/in.pdf">> => Pdf, <<"/workspace/filled.txt">> => <<"done">>}),
    {ok, Turn} = ?P:collect(?O, Tid, <<"run-1">>, facts(#{imported => #{<<"/workspace/in.pdf">> => Sample}})),
    ?assertEqual([<<"filled.txt">>], [N || #{<<"name">> := N} <- maps:get(<<"files">>, Turn)]).

new_bytes_make_a_new_version(_) ->
    Tid = thread(<<"Versions">>),
    workspace(#{<<"/workspace/a.txt">> => <<"v1">>}),
    {ok, T1} = ?P:collect(?O, Tid, <<"run-1">>, facts(#{})),
    workspace(#{<<"/workspace/a.txt">> => <<"v2">>}),
    {ok, T2} = ?P:collect(?O, Tid, <<"run-2">>, facts(#{})),
    {ok, T3} = ?P:collect(?O, Tid, <<"run-3">>, facts(#{})),
    [V1] = ids(T1), [V2] = ids(T2),
    ?assertNotEqual(V1, V2),
    %% the same bytes again: the earlier file
    ?assertEqual([V2], ids(T3)),
    #{<<"version">> := 2, <<"previousId">> := V1, <<"runId">> := <<"run-2">>} = file(V2),
    ?assertEqual({ok, <<"v1">>}, muse_files:bytes(?O, V1)),
    %% every reply keeps its own card
    ?assertEqual([<<"run-1">>, <<"run-2">>, <<"run-3">>], [R || #{<<"runId">> := R} <- ?P:turns(?O, Tid)]),
    {ok, [#{<<"id">> := V1}]} = ?P:files(?O, Tid, <<"run-1">>).

folders_per_conversation(_) ->
    A = thread(<<"Same/title">>),
    B = thread(<<"Same/title">>),
    workspace(#{<<"/workspace/x.txt">> => <<"x">>}),
    {ok, TA} = ?P:collect(?O, A, <<"r">>, facts(#{})),
    {ok, TB} = ?P:collect(?O, B, <<"r">>, facts(#{})),
    Folder = fun(T) -> [Id] = ids(T), muse_files:folder_of(file(Id)) end,
    {ok, #{<<"name">> := <<"Same-title">>, <<"threadId">> := A}} = muse_files:folder(?O, Folder(TA)),
    {ok, #{<<"name">> := <<"Same-title (2)">>, <<"threadId">> := B}} = muse_files:folder(?O, Folder(TB)),
    %% a renamed folder is still the conversation's
    {ok, _} = muse_files:rename_folder(?O, Folder(TA), <<"Mine">>),
    workspace(#{<<"/workspace/y.txt">> => <<"y">>}),
    {ok, TA2} = ?P:collect(?O, A, <<"r2">>, facts(#{})),
    ?assertEqual(Folder(TA), Folder(TA2)),
    ?assertEqual(1, length([F || F = #{<<"name">> := <<"对话产物"/utf8>>} <- muse_files:folders(?O)])).

a_turn_emits_the_products(_) ->
    Tid = thread(<<"Script">>),
    workspace(#{<<"/workspace/hello.py">> => <<"print('hi')\n">>}),
    muse_script_llm:set([{call, <<"write_computer_file">>, #{<<"path">> => <<"/workspace/hello.py">>,
                                                             <<"text">> => <<"print('hi')\n">>}},
                         {text, <<"I wrote hello.py.">>}]),
    Events = turn(Tid, <<"Write a hello script">>),
    Types = [T || #{<<"type">> := T} <- Events],
    ?assertEqual([<<"CUSTOM">>, <<"RUN_FINISHED">>], lists:nthtail(length(Types) - 2, Types)),
    [#{<<"name">> := <<"muse.products">>, <<"value">> := #{<<"runId">> := Run, <<"anchor">> := Anchor,
                                                           <<"files">> := [#{<<"name">> := <<"hello.py">>}]}}] =
        [E || E = #{<<"type">> := <<"CUSTOM">>} <- Events],
    [#{<<"runId">> := Run}] = [E || E = #{<<"type">> := <<"RUN_STARTED">>} <- Events],
    %% the anchor is the whole reply: user, call, result, text
    ?assertEqual(4, Anchor),
    ?assertEqual(Anchor, length(muse_chat_log:messages(?O, Tid))),
    [#{<<"runId">> := Run}] = ?P:turns(?O, Tid).

a_reply_without_files_has_none(_) ->
    Tid = thread(<<"Hello">>),
    muse_script_llm:set([{text, <<"Hello!">>}]),
    Events = turn(Tid, <<"Hi">>),
    ?assertEqual([], [E || E = #{<<"type">> := <<"CUSTOM">>} <- Events]),
    ?assertEqual(0, meck:num_calls(muse_computer, changed_since, '_')),
    ?assertEqual([], ?P:turns(?O, Tid)).

zip_round_trip(_) ->
    Tid = thread(<<"图表"/utf8>>),
    Files = #{<<"/workspace/a.txt">> => <<"alpha">>, <<"/workspace/sub/a.txt">> => <<"beta">>,
              <<"/workspace/图.png"/utf8>> => png()},
    workspace(Files),
    {ok, _} = ?P:collect(?O, Tid, <<"run-1">>, facts(#{})),
    {ok, Name, Zip} = ?P:zip(?O, Tid, <<"run-1">>),
    ?assertEqual(<<"图表-文件.zip"/utf8>>, Name),
    {ok, Entries} = zip:unzip(Zip, [memory]),
    Got = maps:from_list([{unicode:characters_to_binary(N), B} || {N, B} <- Entries]),
    ?assertEqual(#{<<"a.txt">> => <<"alpha">>, <<"a (2).txt">> => <<"beta">>, <<"图.png"/utf8>> => png()}, Got).

zip_names(_) ->
    ?assertEqual([<<"a.txt">>, <<"A (2).txt">>, <<"a (3).txt">>, <<"b">>, <<"b (2)">>, <<"passwd">>,
                  <<"x.tar.gz">>, <<"x.tar (2).gz">>],
                 ?P:entry_names([<<"a.txt">>, <<"A.txt">>, <<"dir/a.txt">>, <<"b">>, <<"b">>, <<"/etc/../passwd">>,
                                 <<"x.tar.gz">>, <<"x.tar.gz">>])),
    [N] = ?P:entry_names([<<"..">>]),
    ?assertNotEqual(<<"..">>, N),
    [?assertEqual(nomatch, binary:match(E, [<<"/">>, <<"\\">>])) || E <- ?P:entry_names([<<"..\\..\\x">>, <<"../y">>])].

zip_size_cap(_) ->
    %% FILES_MAX_MB=1: a zip holds at most 4 MB
    Tid = thread(<<"Big">>),
    workspace(#{<<"/workspace/a.bin">> => binary:copy(<<1>>, 1000 * 1024)}),
    {ok, Turn} = ?P:collect(?O, Tid, <<"run-1">>, facts(#{})),
    {ok, _, _} = ?P:zip(?O, Tid, <<"run-1">>),
    %% the file grew in Files' records (as if the limit had been higher)
    [Id] = ids(Turn),
    _ = muse_store:update(?O, <<"files">>, Id, fun(F) -> {ok, F#{<<"size">> => 5 * 1048576}} end),
    {error, {413, Msg}} = ?P:zip(?O, Tid, <<"run-1">>),
    ?assertNotEqual(nomatch, binary:match(Msg, <<"4 MB">>)).

zip_owner_check(_) ->
    Tid = thread(<<"Mine">>),
    workspace(#{<<"/workspace/a.txt">> => <<"a">>}),
    {ok, _} = ?P:collect(?O, Tid, <<"run-1">>, facts(#{})),
    ?assertMatch({error, {404, _}}, ?P:zip(<<"someone-else">>, Tid, <<"run-1">>)),
    ?assertMatch({error, {404, _}}, ?P:files(<<"someone-else">>, Tid, <<"run-1">>)),
    ?assertMatch({error, {404, _}}, ?P:zip(?O, Tid, <<"other-run">>)),
    %% a deleted file is left out; with none left there is nothing to pack
    {ok, [#{<<"id">> := Id}]} = ?P:files(?O, Tid, <<"run-1">>),
    ok = muse_files:delete(?O, Id),
    {ok, []} = ?P:files(?O, Tid, <<"run-1">>),
    ?assertMatch({error, {404, _}}, ?P:zip(?O, Tid, <<"run-1">>)).

deleting_the_conversation(_) ->
    Tid = thread(<<"Gone">>),
    workspace(#{<<"/workspace/a.txt">> => <<"a">>}),
    {ok, Turn} = ?P:collect(?O, Tid, <<"run-1">>, facts(#{})),
    ok = muse_threads:delete(?O, Tid),
    ?assertEqual([], ?P:turns(?O, Tid)),
    [Id] = ids(Turn),
    {ok, _} = muse_files:get(?O, Id).

prompt_mentions_products(_) ->
    System = muse_chat_agent:system_prompt(),
    ?assertNotEqual(nomatch, binary:match(System, ?P:prompt())),
    %% it is the last sentence, after the mail part
    {Mail, _} = binary:match(System, muse_chat_agent:mail_prompt()),
    {Products, _} = binary:match(System, ?P:prompt()),
    ?assert(Products > Mail).

%% Helpers

png() -> <<137, "PNG\r\n", 26, "\n", 0, 0, 0, 13, "IHDR">>.

sample_id() ->
    [Id] = [I || #{<<"id">> := I, <<"kind">> := <<"pdf">>} <- muse_files:list(?O, unsigned)],
    Id.

turn(Tid, Text) ->
    {started, _RunId, Since, Session} = muse_chat:start_turn(?O, Tid, Text, #{}),
    {ok, Ref, Backlog, _} = beamai_agui_session:subscribe(Session, Since),
    collect_events(Ref, [E || {_, E} <- Backlog]).

collect_events(Ref, Acc) ->
    case [E || E = #{<<"type">> := T} <- Acc, T =:= <<"RUN_FINISHED">> orelse T =:= <<"RUN_ERROR">>] of
        [_ | _] -> Acc;
        [] ->
            receive
                {agui_event, Ref, _Seq, Event} -> collect_events(Ref, Acc ++ [Event]);
                {agui_closed, Ref, _} -> Acc
            after 15000 -> error({no_finish, [T || #{<<"type">> := T} <- Acc]})
            end
    end.
