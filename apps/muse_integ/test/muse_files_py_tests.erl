%% files.py's `changed_since` walk (M9-11): runs the Python unit tests in
%% computer/tests on a temporary directory. Skipped when the host has no
%% python3; the real /workspace protocol is in muse_computer_SUITE (Docker).
-module(muse_files_py_tests).
-include_lib("eunit/include/eunit.hrl").

changed_since_test_() ->
    case os:find_executable("python3") of
        false ->
            [];
        Python ->
            {timeout, 60,
             fun() ->
                     Root = root(),
                     Script = filename:join([Root, "computer", "tests", "test_files.py"]),
                     Port = open_port({spawn_executable, Python},
                                      [{args, ["-I", "-B", Script]}, exit_status, stderr_to_stdout, binary]),
                     {Status, Out} = drain(Port, <<>>),
                     ?assertEqual({0, ok}, {Status, case Status of 0 -> ok; _ -> Out end})
             end}
    end.

root() ->
    Source = proplists:get_value(source, ?MODULE:module_info(compile)),
    filename:dirname(filename:dirname(filename:dirname(filename:dirname(Source)))).

drain(Port, Acc) ->
    receive
        {Port, {data, D}} -> drain(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, S}} -> {S, Acc}
    after 50000 -> error(timeout)
    end.
