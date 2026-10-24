-module(muse_computer_tools_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tool set of OpenMuse computer-tools.ts (engine spec §8.1). The service
%% (`muse_computer`) is mocked; its schemas are the real ones.

-define(O, <<"owner-1">>).
-define(FAILED, <<"Computer operation failed">>).
-define(NAMES, [<<"computer_status">>, <<"start_computer">>, <<"stop_computer">>,
                <<"run_computer_command">>, <<"list_computer_files">>,
                <<"read_computer_file">>, <<"write_computer_file">>, <<"mkdir_computer">>,
                <<"import_computer_pdf">>, <<"export_computer_pdf">>]).

setup(Provider) ->
    meck:new(muse_computer, [passthrough]),
    meck:expect(muse_computer, provider, fun() -> Provider end),
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
    ?assertEqual(
       [<<"Inspect the real Docker computer status and durable command receipts">>,
        <<"Start the configured private Linux computer with networking disabled">>,
        <<"Stop the private Linux computer while preserving /workspace">>,
        <<"Run bash only inside the private computer and return its persisted output and exit receipt">>,
        <<"List files in the computer workspace">>,
        <<"Read a UTF-8 file up to 256 KB inside /workspace">>,
        <<"Save a UTF-8 file up to 256 KB inside /workspace">>,
        <<"Create a directory inside /workspace">>,
        <<"Copy an owned app PDF into the computer without network access">>,
        <<"Import a completed workspace PDF into app Files">>],
       [D || #{description := D} <- tools()]).

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
          {"idempotency key is <scope>:<operationId>", fun idempotency/0},
          {"run pid is a cancel source", fun cancel_pid/0},
          {"argument validation", fun validation/0},
          {"file tools forward their arguments", fun files/0},
          {"Before runs first and its throws become errors", fun before/0},
          {"service errors and crashes map to error results", fun errors/0}]).

lifecycle() ->
    ?assertEqual({ok, #{<<"status">> => <<"stopped">>, <<"owner">> => ?O}},
                 call(<<"computer_status">>, #{})),
    ?assertEqual({ok, #{<<"status">> => <<"running">>}}, call(<<"start_computer">>, #{})),
    ?assertEqual({ok, #{<<"status">> => <<"stopped">>}}, call(<<"stop_computer">>, #{})),
    ?assert(meck:called(muse_computer, start, [?O])),
    ?assert(meck:called(muse_computer, stop, [?O])).

idempotency() ->
    {ok, R} = call(<<"run_computer_command">>,
                   #{<<"command">> => <<"  ls -la  ">>, <<"operationId">> => <<"op-1">>}),
    ?assertEqual(#{<<"command">> => <<"ls -la">>, <<"cwd">> => <<"/workspace">>,
                   <<"status">> => <<"succeeded">>}, R),
    ?assert(meck:called(muse_computer, execute,
                        [?O, #{<<"command">> => <<"ls -la">>, <<"cwd">> => <<"/workspace">>},
                         #{idempotency_key => <<"task:t1:op-1">>, cancel => []}])),
    Chat = tools(<<"chat:thread-1:msg-2">>, fun() -> ok end),
    {ok, _} = call_in(spec(<<"run_computer_command">>, Chat),
                      #{<<"command">> => <<"pwd">>, <<"cwd">> => <<"/workspace/x">>,
                        <<"operationId">> => <<"a:b">>}, beamai_context:new()),
    ?assert(meck:called(muse_computer, execute,
                        [?O, #{<<"command">> => <<"pwd">>, <<"cwd">> => <<"/workspace/x">>},
                         #{idempotency_key => <<"chat:thread-1:msg-2:a:b">>, cancel => []}])).

cancel_pid() ->
    Run = spawn(fun() -> receive stop -> ok end end),
    Ctx = beamai_context:with_state(beamai_context:new(), #{<<"run_pid">> => Run}),
    {ok, _} = call(<<"run_computer_command">>,
                   #{<<"command">> => <<"true">>, <<"operationId">> => <<"op">>}, Ctx),
    ?assert(meck:called(muse_computer, execute,
                        ['_', '_', #{idempotency_key => <<"task:t1:op">>, cancel => [Run]}])),
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
    ?assertEqual({ok, #{<<"path">> => P, <<"entries">> => []}},
                 call(<<"list_computer_files">>, #{<<"path">> => P})),
    ?assertEqual({ok, #{<<"path">> => P, <<"text">> => <<"hi">>}},
                 call(<<"read_computer_file">>, #{<<"path">> => P})),
    {ok, _} = call(<<"write_computer_file">>, #{<<"path">> => P, <<"text">> => <<>>}),
    ?assert(meck:called(muse_computer, write, [?O, P, <<>>])),
    {ok, _} = call(<<"mkdir_computer">>, #{<<"path">> => P}),
    ?assert(meck:called(muse_computer, mkdir, [?O, P])),
    {ok, _} = call(<<"import_computer_pdf">>, #{<<"path">> => P, <<"fileId">> => <<"f-1">>}),
    ?assert(meck:called(muse_computer, import_pdf, [?O, P, <<"f-1">>])),
    ?assertEqual({ok, #{<<"id">> => <<"art-1">>}},
                 call(<<"export_computer_pdf">>, #{<<"path">> => P})),
    ?assert(meck:called(muse_computer, export_pdf, [?O, P])).

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
     ?_assertMatch(<<"The computer is a single-owner Docker Linux container", _/binary>>, Docker),
     %% COMPUTER_DESKTOP unset: the light text
     ?_assertEqual(Docker, muse_computer_tools:instructions())].

%% The desktop variant (COMPUTER_DESKTOP=true; not in OpenMuse): use_desktop
%% between import_computer_pdf and export_computer_pdf, its own
%% instructions, 16 chat steps.

desktop(Flag) ->
    {ok, C} = muse_config:from_env(#{<<"COMPUTER_DESKTOP">> => atom_to_binary(Flag)}),
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
                   "Fails when the computer is stopped; start it first.">>, D),
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
                        <<"receiptId">> => <<"r-1">>,
                        <<"screen">> => #{<<"width">> => 1280, <<"height">> => 800},
                        <<"screenshot">> => <<"attached as an image for this step only">>,
                        <<"screenshotUrl">> => <<"/api/computer/desktop/screenshot?owner=owner-1&expires=1"
                                                 "&signature=s&receipt=r-1">>}},
                 muse_json:decode(Text)),
    %% history keeps only the text view
    ?assertEqual(Text, beamai_tool:result_text({parts, [#{type => text, text => Text}, #{type => image}]})),
    ?assert(meck:called(muse_computer_desktop, desktop_action,
                        [?O, #{<<"action">> => <<"left_click">>, <<"coordinate">> => [1, 2]},
                         #{idempotency_key => <<"task:t1:op-7">>}])),
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
      ?_assertEqual(6, muse_chat_agent:max_steps()),
      ?_assertEqual(muse_computer_tools:instructions(light), muse_computer_tools:instructions())]}.

desktop_instructions_test_() ->
    {setup,
     fun() -> desktop(true) end,
     fun(_) -> persistent_term:erase({muse_config, config}) end,
     fun(_) ->
             D = muse_computer_tools:instructions(),
             Has = fun(P) -> binary:match(D, P) =/= nomatch end,
             [?_assertEqual(muse_computer_tools:instructions(desktop), D),
              ?_assertEqual(16, muse_chat_agent:max_steps()),
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
