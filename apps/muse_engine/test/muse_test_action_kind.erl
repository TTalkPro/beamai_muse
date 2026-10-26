%% @doc A test-only action kind, `test.note`, for the review machinery
%% tests (muse_actions_tests and the suites that need a reviewed action).
%% Executing it stores a note in the owner's `test-notes`.
-module(muse_test_action_kind).
-behaviour(muse_action_kind).

-export([register/0, unregister/0, schema/0, display/1, prepare/2, execute/3, tool/0]).

-define(KIND, <<"test.note">>).

-spec register() -> ok.
register() ->
    muse_actions:register_kind(?KIND, ?MODULE).

-spec unregister() -> ok.
unregister() ->
    muse_actions:unregister_kind(?KIND).

schema() ->
    {object, [{<<"text">>, {string, #{trim => true, min => 1, max => 200}}},
              {<<"fileIds">>, {default, {array, {string, #{}}, #{max => 5}}, []}},
              {<<"targetId">>, {optional, {string, #{min => 1}}}}]}.

display(#{<<"text">> := Text} = Data) ->
    #{title => <<"Write “"/utf8, Text/binary, "”"/utf8>>,
      fields => [{<<"内容"/utf8>>, Text},
                 {<<"附件"/utf8>>, iolist_to_binary(lists:join(<<", ">>, maps:get(<<"fileIds">>, Data, [])))}]}.

%% Files must be owned; a `targetId` reviews the target stored under
%% `{muse_test_action_kind, target}` (with its `version`).
prepare(Owner, Data) ->
    case [E || Id <- maps:get(<<"fileIds">>, Data, []), {error, _} = E <- [muse_files:get(Owner, Id)]] of
        [E | _] -> E;
        [] ->
            case {maps:find(<<"targetId">>, Data), persistent_term:get({?MODULE, target}, undefined)} of
                {{ok, _}, #{target := T, version := V}} ->
                    {ok, #{data => Data#{<<"text">> => maps:get(<<"text">>, T)}, target => T, target_version => V}};
                _ ->
                    {ok, #{data => Data}}
            end
    end.

execute(Owner, #{<<"text">> := Text}, _Review) ->
    Id = muse_ids:uuid(),
    _ = muse_store:put(Owner, <<"test-notes">>, #{<<"id">> => Id, <<"text">> => Text}),
    {ok, <<"Saved note · "/utf8, Id/binary>>}.

tool() ->
    #{name => <<"prepare_note">>, description => <<"Prepare a note for a separate user review">>}.
