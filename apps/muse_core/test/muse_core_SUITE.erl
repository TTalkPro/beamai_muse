-module(muse_core_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([app_boot_and_durability/1, config_error_stops_boot/1, agent_memory_on_bitcask/1]).

all() ->
    [app_boot_and_durability, config_error_stops_boot, agent_memory_on_bitcask].

init_per_testcase(_Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), "data"),
    [{data_dir, Dir} | Config].

end_per_testcase(_Case, _Config) ->
    ok.

%% Boot muse_core on a named peer (Mnesia disc copies need a node name),
%% write to Mnesia and every cask, restart the whole node, read it back.
app_boot_and_durability(Config) ->
    Dir = list_to_binary(?config(data_dir, Config)),
    Env = #{<<"DATA_DIR">> => Dir},
    %% Mnesia's disc schema belongs to the node name: restart under the same name.
    Name = peer_name(),
    Peer1 = start_peer(Name),
    ok = boot(Peer1, Env),
    Doc = #{<<"id">> => <<"t1">>, <<"status">> => <<"queued">>, <<"leaseId">> => null},
    Doc = rpc(Peer1, muse_store, put, [<<"local-user">>, <<"tasks">>, Doc]),
    rpc(Peer1, muse_store, put, [<<"local-user">>, <<"actions">>,
                                 #{<<"id">> => <<"a1">>, <<"status">> => <<"executing">>}]),
    {ok, _} = rpc(Peer1, muse_events_log, append, [<<"local-user">>, <<"t1">>, #{<<"title">> => <<"one">>}]),
    ok = rpc(Peer1, muse_blob, put, [<<"pdf/x">>, <<"%PDF-bytes">>]),
    ok = rpc(Peer1, muse_chat_log, mem_add, [<<"local-user">>, <<"th">>,
                                              [#{role => user, content => <<"museum trip">>}]]),
    {ok, KeyText} = file:read_file(filename:join(Dir, "session-signing-key")),
    peer:stop(Peer1),

    Peer2 = start_peer(Name),
    ok = boot(Peer2, Env),
    ?assertEqual(Doc, rpc(Peer2, muse_store, get, [<<"local-user">>, <<"tasks">>, <<"t1">>])),
    %% executing actions are recovered at boot
    ?assertMatch(#{<<"status">> := <<"outcome_unknown">>},
                 rpc(Peer2, muse_store, get, [<<"local-user">>, <<"actions">>, <<"a1">>])),
    ?assertMatch([#{<<"title">> := <<"one">>}], rpc(Peer2, muse_events_log, list, [<<"local-user">>, <<"t1">>])),
    ?assertEqual({ok, <<"%PDF-bytes">>}, rpc(Peer2, muse_blob, get, [<<"pdf/x">>])),
    ?assertEqual([#{role => user, content => <<"museum trip">>}],
                 rpc(Peer2, muse_chat_log, messages, [<<"local-user">>, <<"th">>])),
    ?assertMatch([{<<"th">>, _, _}], rpc(Peer2, muse_chat_log, search, [<<"local-user">>, <<"museum">>, 5])),
    ?assertEqual({ok, KeyText}, file:read_file(filename:join(Dir, "session-signing-key"))),
    {ok, #{token := Token}} = rpc(Peer2, muse_auth, session, [undefined]),
    ?assertEqual({ok, <<"local-user">>}, rpc(Peer2, muse_auth, owner_from_token, [Token])),
    peer:stop(Peer2).

config_error_stops_boot(Config) ->
    Dir = list_to_binary(?config(data_dir, Config)),
    Peer = start_peer(peer_name()),
    ok = rpc(Peer, application, set_env, [muse_core, env, #{<<"DATA_DIR">> => Dir,
                                                            <<"WORKSPACE_MODE">> => <<"bogus">>}]),
    {error, {muse_core, {{config, Msg}, _}}} = rpc(Peer, application, ensure_all_started, [muse_core]),
    ?assertEqual(<<"WORKSPACE_MODE must be sample or live">>, Msg),
    peer:stop(Peer).

%% beamai_agent keeps multi-turn history in muse_chat_log.
agent_memory_on_bitcask(Config) ->
    {ok, _} = application:ensure_all_started([bitcask, beamai_core, beamai_llm, beamai_agent]),
    Dir = ?config(data_dir, Config),
    {ok, P1} = muse_cask:start_link(chat, filename:join(Dir, "chat"), []),
    {ok, P2} = muse_cask:start_link(chat_index, filename:join(Dir, "chat_index"), [{analyzer, jieba}]),
    ok = muse_test_llm:set([{text, <<"first answer">>}, {text, <<"second answer">>}]),
    Client = beamai_chat_client:add_chat_model(beamai_chat_client:new(), muse_test_llm:model()),
    NewAgent = fun() ->
                   {ok, A} = beamai_agent:new(#{chat_client => Client,
                                                memory => {store, muse_chat_log:handle(<<"u">>)},
                                                conversation_id => <<"thread-1">>}),
                   A
               end,
    {ok, #{content := <<"first answer">>}, _} = beamai_agent:run(NewAgent(), <<"hello">>),
    %% a fresh agent value (as after a restart) still sees the history
    {ok, #{content := <<"second answer">>}, _} = beamai_agent:run(NewAgent(), <<"again">>),
    [{1, First}, {2, Second}] = muse_test_llm:requests(),
    ?assertEqual([<<"hello">>], contents(First)),
    ?assertEqual([<<"hello">>, <<"first answer">>, <<"again">>], contents(Second)),
    ?assertEqual(4, length(muse_chat_log:messages(<<"u">>, <<"thread-1">>))),
    unlink(P1), unlink(P2),
    muse_cask:stop(chat), muse_cask:stop(chat_index).

%% Helpers

contents(Msgs) ->
    [C || #{role := R, content := C} <- Msgs, R =/= system].

peer_name() ->
    list_to_atom("muse_ct_" ++ integer_to_list(erlang:unique_integer([positive]))).

start_peer(Name) ->
    Args = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, _Node} = peer:start_link(#{name => Name, connection => standard_io, args => Args}),
    unlink(Peer),
    Peer.

boot(Peer, Env) ->
    ok = rpc(Peer, application, set_env, [muse_core, env, Env]),
    {ok, _} = rpc(Peer, application, ensure_all_started, [muse_core]),
    ok.

rpc(Peer, M, F, A) ->
    peer:call(Peer, M, F, A, 30000).
