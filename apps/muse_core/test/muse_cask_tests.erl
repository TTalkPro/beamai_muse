-module(muse_cask_tests).
-include_lib("eunit/include/eunit.hrl").

casks_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [fun prefix_end/0, fun events_order_and_isolation/0, fun events_delete/0,
      fun blobs/0, fun chat_log_memory/0, fun chat_search/0, fun seq_survives_restart/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(bitcask),
    Dir = filename:join("/tmp", "muse_cask_tests_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Start = fun(Name, Opts) ->
                {ok, Pid} = muse_cask:start_link(Name, filename:join(Dir, atom_to_list(Name)), Opts),
                unlink(Pid)
            end,
    Start(events, []), Start(blobs, []), Start(chat, []), Start(chat_index, [{analyzer, jieba}]),
    Dir.

cleanup(Dir) ->
    [muse_cask:stop(N) || N <- [events, blobs, chat, chat_index]],
    os:cmd("rm -rf " ++ Dir).

prefix_end() ->
    ?assertEqual(<<"ev/a0">>, muse_cask:prefix_end(<<"ev/a/">>)),
    ?assertEqual(<<"b">>, muse_cask:prefix_end(<<"a", 255>>)),
    ?assertEqual(undefined, muse_cask:prefix_end(<<>>)).

events_order_and_isolation() ->
    [{ok, _} = muse_events_log:append(<<"o">>, <<"t1">>, #{<<"kind">> => <<"step">>,
                                                          <<"title">> => integer_to_binary(N)})
     || N <- lists:seq(1, 25)],
    {ok, _} = muse_events_log:append(<<"o">>, <<"t10">>, #{<<"title">> => <<"other">>}),
    {ok, _} = muse_events_log:append(<<"o2">>, <<"t1">>, #{<<"title">> => <<"other owner">>}),
    Events = muse_events_log:list(<<"o">>, <<"t1">>),
    ?assertEqual([integer_to_binary(N) || N <- lists:seq(1, 25)],
                 [T || #{<<"title">> := T} <- Events]),
    [E | _] = Events,
    ?assertMatch(#{<<"taskId">> := <<"t1">>, <<"id">> := _, <<"date">> := _}, E),
    ?assertEqual(1, length(muse_events_log:list(<<"o">>, <<"t10">>))).

events_delete() ->
    {ok, _} = muse_events_log:append(<<"o">>, <<"gone">>, #{<<"title">> => <<"x">>}),
    ok = muse_events_log:delete_task(<<"o">>, <<"gone">>),
    ?assertEqual([], muse_events_log:list(<<"o">>, <<"gone">>)),
    ?assertEqual(25, length(muse_events_log:list(<<"o">>, <<"t1">>))).

blobs() ->
    Pdf = <<"%PDF-1.7 ", (crypto:strong_rand_bytes(4096))/binary>>,
    ok = muse_blob:put(<<"pdf/1">>, Pdf),
    ok = muse_blob:put(<<"pdf/2">>, <<"two">>),
    ?assertEqual({ok, Pdf}, muse_blob:get(<<"pdf/1">>)),
    ?assertEqual(not_found, muse_blob:get(<<"pdf/none">>)),
    ?assertEqual([<<"pdf/2">>], muse_blob:orphans(<<"pdf/">>, fun(K) -> K =:= <<"pdf/1">> end)),
    ok = muse_blob:delete(<<"pdf/2">>),
    ?assertEqual([<<"pdf/1">>], muse_blob:keys(<<"pdf/">>)).

chat_log_memory() ->
    Mem = muse_chat_log:handle(<<"u1">>),
    Msgs = [#{role => user, content => <<"Plan a museum visit">>},
            #{role => assistant, content => null,
              tool_calls => [#{id => <<"c1">>, name => <<"delegate_task">>, arguments => #{}}]},
            #{role => tool, tool_call_id => <<"c1">>, name => <<"delegate_task">>, content => <<"{\"id\":\"t\"}">>},
            #{role => assistant, content => [#{type => text, text => <<"已保存到 Activity"/utf8>>}]}],
    ok = beamai_chat_memory:mem_add(Mem, <<"th1">>, lists:sublist(Msgs, 2)),
    ok = beamai_chat_memory:mem_add(Mem, <<"th1">>, lists:nthtail(2, Msgs)),
    ?assertEqual(Msgs, beamai_chat_memory:mem_get(Mem, <<"th1">>)),
    ?assertEqual([], beamai_chat_memory:mem_get(Mem, <<"th-none">>)),
    ok = beamai_chat_memory:mem_add(Mem, <<"th2">>, [#{role => user, content => <<"x">>}]),
    ok = beamai_chat_memory:mem_clear(Mem, <<"th2">>),
    ?assertEqual([], beamai_chat_memory:mem_get(Mem, <<"th2">>)).

chat_search() ->
    ok = beamai_chat_memory:mem_add(muse_chat_log:handle(<<"u2">>), <<"th3">>,
                                    [#{role => user, content => <<"秘密的博物馆计划 museum"/utf8>>}]),
    Hits = muse_chat_log:search(<<"u1">>, <<"Museum">>, 10),
    ?assertMatch([{<<"th1">>, _, _}], Hits),
    ?assertMatch([{<<"th1">>, _, _}], muse_chat_log:search(<<"u1">>, <<"保存"/utf8>>, 10)),
    ?assertMatch([{<<"th3">>, _, _}], muse_chat_log:search(<<"u2">>, <<"博物馆"/utf8>>, 10)),
    ?assertEqual([], muse_chat_log:search(<<"u1">>, <<"博物馆"/utf8>>, 10)).

seq_survives_restart() ->
    Dir = muse_cask:dir(events),
    muse_cask:stop(events),
    {ok, Pid} = muse_cask:start_link(events, Dir, []),
    unlink(Pid),
    {ok, _} = muse_events_log:append(<<"o">>, <<"t1">>, #{<<"title">> => <<"after restart">>}),
    Titles = [T || #{<<"title">> := T} <- muse_events_log:list(<<"o">>, <<"t1">>)],
    ?assertEqual(<<"after restart">>, lists:last(Titles)),
    ?assertEqual(26, length(Titles)).
