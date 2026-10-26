%% @doc Desktop actions on the desktop variant of the Docker computer
%% (COMPUTER_DESKTOP=true; not in OpenMuse, whose desktop is E2B). The
%% action schema, receipt lines, input and screenshot sequence follow
%% OpenMuse computer-e2b-desktop.ts (`desktopActionSchema`,
%% `describeDesktopAction`, `desktopInput`, `actionScript`) and the service
%% part of computer.ts (`desktopAction`, `latestScreenshot`); the commands
%% run with `docker exec` instead of the E2B SDK.
%%
%% Everything is argv: a fixed bash script gets the xdotool arguments as
%% positional parameters (`muse_docker:desktop_args/3`), so typed text and
%% key names are never part of a shell string. Input first releases every
%% modifier (exit 3: the input failed); the screenshot runs after a 0.5 s
%% settle in a second exec (exit 4: the screenshot failed) and comes back as
%% base64 on stdout.
%%
%% Actions run under the computer lease and leave receipts of kind
%% `computer-desktop-actions`, apart from the command receipts. The intent is
%% persisted as `interrupted` before input is dispatched, so a crash never
%% erases uncertain input; a repeated idempotency key returns the stored
%% receipt and never sends input again. Only the latest screenshot is kept:
%% `${DATA_DIR}/desktop-screens/<sha256hex(owner)>.jpg` (written to
%% `<receiptId>.tmp`, then renamed) with the record
%% `computer-desktop-screens/latest`.
%%
%% `frame/1` is the page's live view: a screenshot without input, lease or
%% receipt, never stored.
%%
%% Every function takes a computer `muse_computer:ref()`. The legacy
%% computer keeps the names above; a pool computer's latest screenshot is
%% `computer-desktop-screens/latest:<computerId>` and
%% `<sha256hex(owner)>-<computerId>.jpg` and its receipts carry
%% `computerId`. Every signed URL adds `&computer=<computerId>` (outside the
%% signature, which proves the owner; the route only serves that owner's
%% computers).
-module(muse_computer_desktop).

-export([enabled/0, status/1, forget/1,
         desktop_action/2, desktop_action/3,
         latest_screenshot/1, latest_screenshot/2, frame/1,
         screenshot_url/2, frame_url/1,
         action_schema/0, describe_action/1, input_argv/1,
         input_script/0, shot_script/2, resolution/0]).

-export_type([shot/0, action/0]).

-define(ERR(Status, Msg), throw({?MODULE, Status, Msg})).
-define(ACTIONS, <<"computer-desktop-actions">>).
-define(SCREENS, <<"computer-desktop-screens">>).
-define(MIME, <<"image/jpeg">>).
-define(WIDTH, 1280).
-define(HEIGHT, 800).
-define(SHOT_FILE, <<"/tmp/openmuse-screenshot.jpg">>).
-define(FRAME_FILE, <<"/tmp/openmuse-frame.jpg">>).
-define(SCREENSHOT_PATH, <<"/api/computer/desktop/screenshot">>).
-define(RELEASE_MODIFIERS, <<"xdotool keyup Shift_L Shift_R Control_L Control_R Alt_L Alt_R "
                             "Super_L Super_R Meta_L Meta_R ISO_Level3_Shift">>).
-define(INTENT, <<"Desktop input is being dispatched; its outcome is unknown until confirmed. "
                  "Inspect a fresh screenshot before repeating the action; do not "
                  "automatically retry it.">>).
-define(UNCERTAIN, <<"The desktop input outcome is unknown: it may already have been performed. "
                     "Inspect a fresh screenshot before repeating the action; do not "
                     "automatically retry it.">>).
-define(NO_SHOT, <<"Action performed; the screenshot could not be taken. Take a screenshot "
                   "before retrying the action.">>).
-define(SHOT_FAILED, <<"The desktop screenshot failed">>).
-define(NOT_ENABLED, <<"This computer has no desktop. Set COMPUTER_DESKTOP=true and build "
                       "the desktop computer image.">>).
-define(ACTION_NAMES, [<<"screenshot">>, <<"left_click">>, <<"double_click">>, <<"right_click">>,
                       <<"mouse_move">>, <<"type">>, <<"key">>, <<"scroll">>, <<"wait">>]).

-type error() :: {error, {pos_integer(), binary()}}.
-type action() :: #{binary() => term()}.
-type shot() :: #{receipt := map(), width := pos_integer(), height := pos_integer(),
                  image := binary(), mime_type := binary(), data := binary(),
                  uncertain := boolean(), warning := binary() | undefined}.

%% @doc COMPUTER_DESKTOP: the desktop variant is configured.
-spec enabled() -> boolean().
enabled() ->
    muse_config:get(computer_desktop, false) =:= true.

%% @doc What the desktop page needs: the computer status, the screen size
%% and the latest screenshot (a signed same-origin URL, or null).
-spec status(muse_computer:ref()) -> {ok, map()} | error().
status(Ref) ->
    guard(fun() ->
                  desktop_only(),
                  #{<<"status">> := Status} = Snapshot = muse_computer:snapshot(Ref),
                  Latest = muse_store:get(muse_computer:owner(Ref), ?SCREENS, latest_id(Ref)),
                  Base = #{<<"status">> => Status,
                           <<"running">> => Status =:= <<"running">>,
                           <<"width">> => ?WIDTH, <<"height">> => ?HEIGHT,
                           <<"screenshot">> => null, <<"takenAt">> => null},
                  Shot = case Latest of
                             #{<<"receiptId">> := Id} ->
                                 Base#{<<"screenshot">> => screenshot_url(Ref, Id),
                                       <<"receiptId">> => Id,
                                       <<"takenAt">> => maps:get(<<"takenAt">>, Latest, null)};
                             _ -> Base
                         end,
                  {ok, case Snapshot of
                           #{<<"message">> := Msg} -> Shot#{<<"message">> => Msg};
                           _ -> Shot
                       end}
          end).

-spec desktop_action(muse_computer:ref(), term()) -> {ok, shot()} | error().
desktop_action(Ref, Raw) ->
    desktop_action(Ref, Raw, #{}).

%% @doc One screenshot, click, key or typing action on the running desktop,
%% recorded as a receipt. A stopped computer fails unless `auto_start` (the
%% agent tool; not in OpenMuse) starts it first, after validation.
-spec desktop_action(muse_computer:ref(), term(),
                     #{idempotency_key => binary(), auto_start => boolean()}) -> {ok, shot()} | error().
desktop_action(Ref, Raw, Opts) ->
    guard(fun() ->
                  desktop_only(),
                  Schema = action_schema(),
                  Action = case muse_validate:parse(Schema, Raw) of
                               {ok, A} -> A;
                               {error, {S0, M0}} -> ?ERR(S0, M0)
                           end,
                  Key = maps:get(idempotency_key, Opts, undefined),
                  Id = case Key of
                           undefined -> muse_ids:uuid();
                           _ -> muse_ids:sha256hex(<<"computer-desktop-action:", Key/binary>>)
                       end,
                  %% The receipt line truncates typed text, so bind the complete validated input.
                  Hash = muse_ids:sha256hex(muse_json:encode(muse_validate:ordered(Schema, Action))),
                  case maps:get(auto_start, Opts, false) of
                      true -> unwrap_ok(muse_computer:ensure_running(Ref));
                      false -> ok
                  end,
                  case muse_computer:locked(Ref, fun() -> act(Ref, Action, Id, Key, Hash) end) of
                      {error, {S, M}} -> ?ERR(S, M);
                      Shot -> {ok, Shot}
                  end
          end).

-spec latest_screenshot(muse_computer:ref()) -> {ok, #{mime_type := binary(), bytes := binary()}} | error().
latest_screenshot(Ref) ->
    latest_screenshot(Ref, undefined).

%% @doc The latest desktop screenshot, or the one `ReceiptId` took if it is
%% still the latest (404 `No desktop screenshot yet` otherwise).
-spec latest_screenshot(muse_computer:ref(), binary() | undefined) ->
    {ok, #{mime_type := binary(), bytes := binary()}} | error().
latest_screenshot(Ref, ReceiptId) ->
    guard(fun() -> desktop_only(), {ok, screenshot(Ref, ReceiptId)} end).

%% @doc A fresh screenshot for the page's live view: no input, no lease, no
%% receipt, not stored. 409 when the computer is stopped.
-spec frame(muse_computer:ref()) -> {ok, #{mime_type := binary(), bytes := binary()}} | error().
frame(Ref) ->
    guard(fun() ->
                  desktop_only(),
                  case muse_computer:require_enabled() of
                      ok -> ok;
                      {error, {S0, M0}} -> ?ERR(S0, M0)
                  end,
                  Session = unwrap(muse_computer_docker:running(Ref)),
                  case capture(Session, false, ?FRAME_FILE) of
                      {ok, Image} -> {ok, #{mime_type => ?MIME, bytes => Image}};
                      error -> ?ERR(502, ?SHOT_FAILED)
                  end
          end).

%% @doc A same-origin signed URL of the screenshot `ReceiptId` took (for
%% `<img>` tags, which cannot send a Bearer header).
-spec screenshot_url(muse_computer:ref(), binary()) -> binary().
screenshot_url(Ref, ReceiptId) ->
    <<(signed(Ref))/binary,
      "&receipt=", (muse_signing:encode_uri_component(ReceiptId))/binary>>.

%% @doc A same-origin signed URL of a live frame (`frame/1`).
-spec frame_url(muse_computer:ref()) -> binary().
frame_url(Ref) ->
    <<(signed(Ref))/binary, "&live=1">>.

%% @doc Drop the computer's desktop receipts and latest screenshot (pool
%% delete).
-spec forget(muse_computer:ref()) -> ok.
forget(Ref) ->
    Owner = muse_computer:owner(Ref),
    _ = [muse_store:remove(Owner, ?ACTIONS, Id)
         || R = #{<<"id">> := Id} <- muse_store:list(Owner, ?ACTIONS), muse_computer:belongs(Ref, R)],
    muse_store:remove(Owner, ?SCREENS, latest_id(Ref)),
    _ = file:delete(filename:join(screens_dir(), blob(Ref))),
    ok.

-spec resolution() -> {pos_integer(), pos_integer()}.
resolution() -> {?WIDTH, ?HEIGHT}.

%% @doc `desktopActionSchema`: one GUI action shaped like Anthropic's
%% computer-use tool. Coordinates are native screenshot pixels.
-spec action_schema() -> muse_validate:schema().
action_schema() ->
    {refine, {object, action_fields()}, fun refine_action/1}.

%% @doc `describeDesktopAction`: the receipt line, e.g.
%% `desktop left_click (640, 400)`.
-spec describe_action(action()) -> binary().
describe_action(A = #{<<"action">> := Action}) ->
    Parts = [<<"desktop">>, Action,
             case A of
                 #{<<"coordinate">> := [X, Y]} -> <<"(", (num(X))/binary, ", ", (num(Y))/binary, ")">>;
                 _ -> false
             end,
             case A of
                 #{<<"text">> := T} when T =/= <<>> -> muse_json:encode(muse_js:slice(T, 200));
                 _ -> false
             end,
             case A of
                 #{<<"scroll_direction">> := D} ->
                     <<D/binary, " ", (num(maps:get(<<"scroll_amount">>, A, 3)))/binary>>;
                 _ -> false
             end,
             case Action of
                 <<"wait">> -> <<(num(maps:get(<<"duration">>, A, 1)))/binary, "s">>;
                 _ -> false
             end],
    iolist_to_binary(lists:join(<<" ">>, [P || P <- Parts, P =/= false])).

%% @doc `desktopInput` as argv: the xdotool (or sleep) command of one
%% action, `undefined` for a plain screenshot. The text of `type` and the
%% key names of `key` are single elements after `--`.
-spec input_argv(action()) -> [binary()] | undefined.
input_argv(A = #{<<"action">> := Action}) ->
    At = case A of
             #{<<"coordinate">> := [X, Y]} -> [<<"mousemove">>, <<"--sync">>, num(X), num(Y)];
             _ -> []
         end,
    X11 = fun(Args) -> [<<"xdotool">> | Args] end,
    case Action of
        <<"screenshot">> -> undefined;
        <<"left_click">> -> X11(At ++ [<<"click">>, <<"1">>]);
        <<"double_click">> -> X11(At ++ [<<"click">>, <<"--repeat">>, <<"2">>, <<"--delay">>, <<"120">>, <<"1">>]);
        <<"right_click">> -> X11(At ++ [<<"click">>, <<"3">>]);
        <<"mouse_move">> -> X11(At);
        <<"type">> -> X11([<<"type">>, <<"--delay">>, <<"12">>, <<"--">>, maps:get(<<"text">>, A)]);
        <<"key">> ->
            X11([<<"key">>, <<"--">> | key_names(maps:get(<<"text">>, A))]);
        <<"scroll">> ->
            Button = case maps:get(<<"scroll_direction">>, A, <<"down">>) of
                         <<"up">> -> <<"4">>;
                         <<"down">> -> <<"5">>;
                         <<"left">> -> <<"6">>;
                         <<"right">> -> <<"7">>
                     end,
            X11(At ++ [<<"click">>, <<"--repeat">>, num(maps:get(<<"scroll_amount">>, A, 3)), Button]);
        <<"wait">> -> [<<"sleep">>, num(maps:get(<<"duration">>, A, 1))]
    end.

%% @doc The fixed input script: `"$@"` is the argv of `input_argv/1`, and
%% only xdotool and sleep may run. xdotool input releases every modifier
%% first (a modifier left held turns every later click and key into a
%% shortcut). Exit 3: the input failed.
-spec input_script() -> binary().
input_script() ->
    lines([<<"case \"$1\" in xdotool|sleep) ;; *) exit 2 ;; esac">>,
           <<"[ \"$1\" = xdotool ] && ", ?RELEASE_MODIFIERS/binary>>,
           <<"\"$@\" || exit 3">>]).

%% @doc OpenMuse `actionScript`, called with `"sleep 0.5"` after input: a
%% short settle, then a JPEG screenshot to `File`, printed as base64
%% (exit 3: the settle failed, 4: the screenshot).
-spec shot_script(boolean(), binary()) -> binary().
shot_script(AfterInput, File) ->
    Settle = case AfterInput of
                 true -> [<<"sleep 0.5 || exit 3">>, <<"sleep 0.5">>];
                 false -> []
             end,
    lines(Settle ++ [<<"scrot --pointer --quality 80 --overwrite ", File/binary, " || exit 4">>,
                     <<"base64 -w0 ", File/binary, " || exit 4">>]).

%% Internal

guard(Fun) ->
    try
        Fun()
    catch
        throw:{?MODULE, Status, Msg} -> {error, {Status, Msg}}
    end.

unwrap({ok, V}) -> V;
unwrap({error, {S, M}}) -> ?ERR(S, M).

unwrap_ok(ok) -> ok;
unwrap_ok({error, {S, M}}) -> ?ERR(S, M).

signed(Ref) ->
    Path = muse_signing:signed_path(muse_computer:owner(Ref), ?SCREENSHOT_PATH),
    <<Path/binary, "&computer=", (muse_computer:computer_id(Ref))/binary>>.

latest_id(Ref) ->
    case muse_computer:is_legacy(Ref) of
        true -> <<"latest">>;
        false -> <<"latest:", (muse_computer:computer_id(Ref))/binary>>
    end.

%% OpenMuse `desktopOnly()`: the enabled check first.
desktop_only() ->
    enabled() orelse ?ERR(404, ?NOT_ENABLED),
    ok.

action_fields() ->
    [{<<"action">>, {enum, ?ACTION_NAMES}},
     {<<"coordinate">>,
      {optional, {desc, <<"[x, y] in screenshot pixels. Clicks and scroll without it use the pointer">>,
                  {array, {integer, #{min => 0}}, #{min => 2, max => 2}}}}},
     {<<"text">>,
      {optional, {desc, <<"Text for type; for key, xdotool key names or combos such as Return or ctrl+l">>,
                  {string, #{min => 1, max => 1000}}}}},
     {<<"scroll_direction">>, {optional, {enum, [<<"up">>, <<"down">>, <<"left">>, <<"right">>]}}},
     {<<"scroll_amount">>,
      {optional, {desc, <<"Wheel clicks, default 3">>, {integer, #{min => 1, max => 15}}}}},
     {<<"duration">>,
      {optional, {desc, <<"Seconds to wait, default 1">>, {number, #{min => 0.1, max => 10}}}}}].

%% The superRefine issues, in OpenMuse order.
refine_action(A = #{<<"action">> := Action}) ->
    Has = fun(K) -> maps:is_key(K, A) end,
    Need = fun(Field, true) -> [<<Action/binary, " needs ", Field/binary>> || not Has(Field)];
              (_, false) -> []
           end,
    Key = case A of
              #{<<"action">> := <<"key">>, <<"text">> := T} ->
                  case re:run(T, <<"^[A-Za-z0-9_+ -]+$">>, [{capture, none}]) =:= match
                      andalso not lists:any(fun xdotool_command/1, key_names(T)) of
                      true -> [];
                      false -> [<<"Use xdotool key names, e.g. ctrl+l">>]
                  end;
              _ ->
                  []
          end,
    Screen = case maps:get(<<"coordinate">>, A, [0, 0]) of
                 [X, Y] when X >= ?WIDTH; Y >= ?HEIGHT -> [<<"The screen is 1280x800">>];
                 _ -> []
             end,
    Issues = Need(<<"coordinate">>, Action =:= <<"mouse_move">>)
        ++ Need(<<"text">>, Action =:= <<"type">> orelse Action =:= <<"key">>)
        ++ Need(<<"scroll_direction">>, Action =:= <<"scroll">>)
        ++ Key ++ Screen,
    case Issues of
        [] -> ok;
        _ -> {error, iolist_to_binary(lists:join(<<"; ">>, Issues))}
    end.

num(N) -> muse_json:number(N).

key_names(Text) ->
    binary:split(Text, [<<" ">>, <<"\t">>, <<"\n">>, <<"\r">>], [global, trim_all]).

%% Not in OpenMuse: xdotool chains commands, and `key` stops at the first
%% argument that names one (case-insensitively), so `key -- shift exec rm x`
%% would run a program. Such names (and the prefixes of xdotool's command
%% families, for newer versions) are refused as key names; no X keysym
%% has these names, except the rarely used `Help`.
xdotool_command(Name) ->
    Lower = string:lowercase(Name),
    lists:member(Lower, [<<"exec">>, <<"help">>, <<"search">>, <<"selectwindow">>, <<"sleep">>,
                         <<"type">>, <<"version">>, <<"click">>])
        orelse lists:any(fun(Prefix) -> binary:longest_common_prefix([Prefix, Lower]) =:= byte_size(Prefix) end,
                         [<<"key">>, <<"mouse">>, <<"window">>, <<"get">>, <<"set_">>, <<"behave">>]).

lines(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

act(Ref, Action, Id, Key, Hash) ->
    Previous = case Key of
                   undefined -> undefined;
                   _ -> muse_store:get(muse_computer:owner(Ref), ?ACTIONS, Id)
               end,
    Previous =:= undefined orelse muse_computer:belongs(Ref, Previous)
        orelse ?ERR(409, <<"This operation ID already belongs to a different desktop action">>),
    case Previous of
        #{} -> replay(Ref, Previous, Hash);
        undefined -> dispatch(Ref, Action, Id, Key, Hash)
    end.

replay(Ref, Previous = #{<<"id">> := Id}, Hash) ->
    maps:get(<<"actionHash">>, Previous, undefined) =:= Hash
        orelse ?ERR(409, <<"This operation ID already belongs to a different desktop action">>),
    %% Only the latest image is retained. Never dispatch again just to refresh it.
    Screen = try screenshot(Ref, Id) catch _:_ -> undefined end,
    {Image, Mime} = case Screen of
                        #{bytes := B, mime_type := M} -> {B, M};
                        undefined -> {<<>>, ?MIME}
                    end,
    #{receipt => Previous, width => ?WIDTH, height => ?HEIGHT, image => Image, mime_type => Mime,
      data => base64:encode(Image),
      uncertain => maps:get(<<"status">>, Previous, <<>>) =:= <<"interrupted">>,
      warning => <<"This operation ID already has a receipt; no new desktop input was sent. ",
                   (case Screen of
                        undefined -> <<"Take a fresh screenshot before deciding what to do next.">>;
                        _ -> <<"The saved screenshot is attached.">>
                    end)/binary>>}.

dispatch(Ref, Action, Id, Key, Hash) ->
    Receipt0 = #{<<"id">> => Id,
                 <<"command">> => describe_action(Action),
                 <<"cwd">> => <<"/workspace">>,
                 <<"status">> => <<"succeeded">>,
                 <<"stdout">> => <<>>,
                 <<"stderr">> => <<>>,
                 <<"truncated">> => false,
                 <<"startedAt">> => muse_time:now_iso()},
    Receipt1 = case Key of
                   undefined -> Receipt0;
                   _ -> Receipt0#{<<"actionHash">> => Hash}
               end,
    Receipt = case muse_computer:is_legacy(Ref) of
                  true -> Receipt1;
                  false -> Receipt1#{<<"computerId">> => muse_computer:computer_id(Ref)}
              end,
    Session = unwrap(muse_computer_docker:running(Ref)),
    %% Save intent before dispatch: a process crash must not erase uncertain input.
    Before = fun() ->
                     muse_store:put(muse_computer:owner(Ref), ?ACTIONS, Receipt#{<<"status">> => <<"interrupted">>,
                                                              <<"stderr">> => ?INTENT})
             end,
    Shot = try
               perform(Session, Action, Before)
           catch
               Class:Reason:Stack ->
                   Message = case {Class, Reason} of
                                 {throw, {_, _, M}} when is_binary(M) -> M;
                                 _ -> <<"Desktop action failed">>
                             end,
                   _ = muse_store:put(muse_computer:owner(Ref), ?ACTIONS,
                                      Receipt#{<<"status">> => <<"failed">>, <<"stderr">> => Message,
                                               <<"completedAt">> => muse_time:now_iso()}),
                   erlang:raise(Class, Reason, Stack)
           end,
    #{image := Image, uncertain := Uncertain, warning := Warning0} = Shot,
    Done = muse_time:now_iso(),
    Saved0 = Receipt#{<<"status">> => case Uncertain of
                                         true -> <<"interrupted">>;
                                         false -> <<"succeeded">>
                                     end,
                      <<"stdout">> => case Warning0 of
                                          undefined -> <<"Screenshot ", (integer_to_binary(?WIDTH))/binary,
                                                         "x", (integer_to_binary(?HEIGHT))/binary>>;
                                          _ -> Warning0
                                      end,
                      <<"stderr">> => case {Uncertain, Warning0} of
                                          {false, _} -> <<>>;
                                          {true, undefined} -> <<"Desktop input outcome is unknown">>;
                                          {true, _} -> Warning0
                                      end,
                      <<"completedAt">> => Done},
    Saved = case Uncertain of
                true -> Saved0;
                false -> Saved0#{<<"exitCode">> => 0}
            end,
    Warning = try
                  _ = muse_store:put(muse_computer:owner(Ref), ?ACTIONS, Saved),
                  case Image of
                      <<>> -> ok;
                      _ -> store_screenshot(Ref, Id, Image, Done)
                  end,
                  Warning0
              catch
                  _:_ when Uncertain ->
                      <<Warning0/binary, " Its final receipt or screenshot could not be saved.">>;
                  _:_ ->
                      <<"Action performed; its receipt or screenshot could not be saved. "
                        "Take a screenshot before retrying the action.">>
              end,
    #{receipt => Saved, width => ?WIDTH, height => ?HEIGHT, image => Image, mime_type => ?MIME,
      data => base64:encode(Image), uncertain => Uncertain, warning => Warning}.

%% OpenMuse `act`: the input (if any), then the screenshot. Throws when
%% nothing was sent and the screenshot fails; after input the result
%% reports the failure instead.
perform(Session, Action, BeforeInput) ->
    Input = input_argv(Action),
    Uncertain = case Input of
                    undefined ->
                        false;
                    _ ->
                        _ = BeforeInput(),
                        %% xdotool dispatches sequentially: a later failure can follow a
                        %% delivered click or Return, and a lost client cannot tell
                        %% whether input occurred. Never replay it here.
                        case muse_computer_docker:desktop(Session, input_script(), Input) of
                            #{exit_code := 0, timed_out := false, interrupted := false} -> false;
                            _ -> true
                        end
                end,
    Warning = case Uncertain of
                  true -> ?UNCERTAIN;
                  false -> undefined
              end,
    case capture(Session, Input =/= undefined, ?SHOT_FILE) of
        {ok, Image} ->
            #{image => Image, uncertain => Uncertain, warning => Warning};
        error when Input =:= undefined ->
            ?ERR(502, ?SHOT_FAILED);
        error ->
            #{image => <<>>, uncertain => Uncertain,
              warning => case Warning of
                             undefined -> ?NO_SHOT;
                             _ -> Warning
                         end}
    end.

capture(Session, AfterInput, File) ->
    try muse_computer_docker:desktop(Session, shot_script(AfterInput, File), []) of
        #{exit_code := 0, timed_out := false, interrupted := false, truncated := false,
          stdout := Out} ->
            try base64:decode(string:trim(Out)) of
                <<16#FF, 16#D8, 16#FF, _/binary>> = Image -> {ok, Image};
                _ -> error
            catch
                _:_ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end.

store_screenshot(Ref, ReceiptId, Image, TakenAt) ->
    Dir = screens_dir(),
    ok = filelib:ensure_path(Dir),
    ok = file:change_mode(Dir, 8#700),
    Blob = blob(Ref),
    Temporary = filename:join(Dir, <<ReceiptId/binary, ".tmp">>),
    try
        {ok, Fd} = file:open(Temporary, [write, exclusive, binary, raw]),
        try
            ok = file:change_mode(Temporary, 8#600),
            ok = file:write(Fd, Image)
        after
            ok = file:close(Fd)
        end,
        ok = file:rename(Temporary, filename:join(Dir, Blob))
    after
        _ = file:delete(Temporary)
    end,
    _ = muse_store:put(muse_computer:owner(Ref), ?SCREENS, #{<<"id">> => latest_id(Ref),
                                          <<"receiptId">> => ReceiptId,
                                          <<"mimeType">> => ?MIME,
                                          <<"blob">> => Blob,
                                          <<"takenAt">> => TakenAt}),
    ok.

screenshot(Ref, ReceiptId) ->
    Shot = muse_store:get(muse_computer:owner(Ref), ?SCREENS, latest_id(Ref)),
    Stale = Shot =:= undefined
        orelse (ReceiptId =/= undefined andalso maps:get(<<"receiptId">>, Shot, undefined) =/= ReceiptId),
    Stale andalso ?ERR(404, <<"No desktop screenshot yet">>),
    Blob = blob(Ref),
    Bytes = case maps:get(<<"blob">>, Shot, undefined) of
                Blob ->
                    case file:read_file(filename:join(screens_dir(), Blob)) of
                        {ok, B} -> B;
                        {error, _} -> ?ERR(404, <<"No desktop screenshot yet">>)
                    end;
                _ ->
                    ?ERR(404, <<"No desktop screenshot yet">>)
            end,
    #{mime_type => maps:get(<<"mimeType">>, Shot, ?MIME), bytes => Bytes}.

blob(Ref) ->
    Hash = muse_ids:sha256hex(muse_computer:owner(Ref)),
    case muse_computer:is_legacy(Ref) of
        true -> <<Hash/binary, ".jpg">>;
        false -> <<Hash/binary, "-", (muse_computer:computer_id(Ref))/binary, ".jpg">>
    end.

screens_dir() ->
    filename:join(muse_config:get(data_dir), "desktop-screens").
