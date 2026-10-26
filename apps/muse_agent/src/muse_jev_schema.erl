%% @doc Jev choice-panel schemas: OpenMuse `packages/domain/src/jev.ts`
%% (designs/ref/openmuse-engine-spec.md §10.2).
%%
%% The zod schemas are `.strict()`, which `muse_validate` objects are not
%% (they strip unknown keys), so `check/2` first rejects unknown keys with
%% zod's message (`Unrecognized key: "x"`) and then validates. Panels also
%% run the cross-field rules of `jevPanelSchema.superRefine`.
-module(muse_jev_schema).

-export([action_prefix/0, encode_action/1, parse_action/1,
         source/0, option/0, option_input/0, panel/0, action/0, tool_params/0,
         check/2, check_panel/1]).

-define(PREFIX_S, "[OpenMuse choice] ").
-define(PREFIX, <<?PREFIX_S>>).

-spec action_prefix() -> binary().
action_prefix() -> ?PREFIX.

%% @doc `encodeJevAction`: the prefix plus `JSON.stringify` of the action in
%% schema key order.
-spec encode_action(map()) -> {ok, binary()} | {error, binary()}.
encode_action(Action) ->
    case check(action(), Action) of
        {ok, Valid} -> {ok, <<?PREFIX/binary, (muse_json:encode(muse_validate:ordered(action(), Valid)))/binary>>};
        {error, _} = Error -> Error
    end.

%% @doc `parseJevAction`: `error` when the text is not a choice (no prefix),
%% `{error, Msg}` when the prefixed payload is not valid JSON or not a valid
%% action.
-spec parse_action(binary()) -> {ok, map()} | error | {error, binary()}.
parse_action(<<?PREFIX_S, Json/binary>>) ->
    case muse_json:decode(Json) of
        {ok, Value} -> check(action(), Value);
        {error, _} -> {error, <<"The choice could not be read">>}
    end;
parse_action(Text) when is_binary(Text) ->
    error.

-spec source() -> muse_validate:schema().
source() ->
    {object, [{<<"title">>, short_text()}, {<<"url">>, http_url()}]}.

-spec option() -> muse_validate:schema().
option() ->
    {object, [{<<"id">>, id()} | option_fields()]}.

%% @doc The tool's option input: `jevOptionSchema.omit({id}).extend({id: optional})`.
-spec option_input() -> muse_validate:schema().
option_input() ->
    {object, option_fields() ++ [{<<"id">>, {optional, id()}}]}.

-spec panel() -> muse_validate:schema().
panel() ->
    {object, [{<<"id">>, id()},
              {<<"threadId">>, id()},
              {<<"turnId">>, id()},
              {<<"candidateSetVersion">>, {integer, #{min => 1}}},
              {<<"type">>, {enum, [<<"clarification">>, <<"comparison">>]}},
              {<<"title">>, short_text()},
              {<<"options">>, {array, option(), #{min => 1, max => 12}}},
              {<<"selectedId">>, {optional, id()}},
              {<<"preferredId">>, {optional, id()}},
              {<<"mode">>, {enum, [<<"sample">>, <<"live">>]}}]}.

-spec action() -> muse_validate:schema().
action() ->
    {object, [{<<"panelId">>, id()},
              {<<"threadId">>, id()},
              {<<"candidateSetVersion">>, {integer, #{min => 1}}},
              {<<"optionId">>, id()}]}.

%% @doc `presentChoicesParameters` (§10.3).
-spec tool_params() -> muse_validate:schema().
tool_params() ->
    {refine,
     {object, [{<<"message">>, text(2000)},
               {<<"context">>, text(8000)},
               {<<"title">>, text(200)},
               {<<"control">>, {enum, [<<"clarification">>, <<"comparison">>]}},
               {<<"options">>, {array, option_input(), #{max => 12}}},
               {<<"refinementPanelId">>, {optional, id()}}]},
     fun(#{<<"options">> := []} = Input) when not is_map_key(<<"refinementPanelId">>, Input) ->
             {error, <<"New choices need at least one option">>};
        (_) -> ok
     end}.

%% @doc Strict validation: unknown keys anywhere in the value are errors.
-spec check(muse_validate:schema(), term()) -> {ok, term()} | {error, binary()}.
check(Schema, Value) ->
    case unknown(Schema, Value) of
        [] ->
            case muse_validate:check(Schema, Value) of
                {ok, V} -> {ok, V};
                {error, Msgs} -> {error, join(Msgs)}
            end;
        Msgs ->
            {error, join(Msgs)}
    end.

%% @doc `jevPanelSchema.parse`: the shape plus the superRefine rules.
-spec check_panel(term()) -> {ok, map()} | {error, binary()}.
check_panel(Value) ->
    case check(panel(), Value) of
        {ok, Panel} ->
            case panel_rules(Panel) of
                [] -> {ok, Panel};
                Msgs -> {error, join(Msgs)}
            end;
        Error ->
            Error
    end.

%% Internal

id() -> {string, #{trim => true, min => 1, max => 200}}.

short_text() -> id().

text(Max) -> {string, #{trim => true, min => 1, max => Max}}.

http_url() ->
    {refine, {string, #{url => true, max => 4096}},
     fun(Url) ->
             case uri_string:parse(Url) of
                 #{scheme := S} when is_binary(S) ->
                     case string:lowercase(S) of
                         <<"http">> -> ok;
                         <<"https">> -> ok;
                         _ -> {error, <<"Source URL must use HTTP or HTTPS">>}
                     end;
                 _ -> {error, <<"Source URL must use HTTP or HTTPS">>}
             end
     end}.

option_fields() ->
    [{<<"label">>, short_text()},
     {<<"details">>, {array, text(600), #{max => 4}}},
     {<<"sources">>, {array, source(), #{max => 5}}}].

panel_rules(#{<<"type">> := Type, <<"options">> := Options} = Panel) ->
    Ids = [Id || #{<<"id">> := Id} <- Options],
    Dups = length(Ids) - length(lists:usort(Ids)),
    Unsourced = [O || #{<<"sources">> := []} = O <- Options],
    Comparison = Type =:= <<"comparison">>,
    [<<"Duplicate option ID">> || _ <- lists:seq(1, Dups)]
        ++ [<<"Comparison options need sources">> || Comparison, _ <- Unsourced]
        ++ [<<"Comparison panel can show at most three options">> || Comparison, length(Options) > 3]
        ++ missing(<<"selectedId">>, <<"Selected option is missing">>, Panel, Ids)
        ++ missing(<<"preferredId">>, <<"Preferred option is missing">>, Panel, Ids).

missing(Key, Msg, Panel, Ids) ->
    case maps:find(Key, Panel) of
        {ok, Id} -> [Msg || not lists:member(Id, Ids)];
        error -> []
    end.

unknown({object, Fields}, M) when is_map(M) ->
    Extra = [K || K <- maps:keys(M), not lists:keymember(K, 1, Fields)],
    Own = case Extra of
              [] -> [];
              [K] -> [<<"Unrecognized key: ", (quote(K))/binary>>];
              Ks -> [iolist_to_binary(["Unrecognized keys: ", lists:join(", ", [quote(K) || K <- Ks])])]
          end,
    Own ++ lists:append([unknown(S, maps:get(K, M)) || {K, S} <- Fields, is_map_key(K, M)]);
unknown({array, Item, _}, L) when is_list(L) ->
    lists:append([unknown(Item, X) || X <- L]);
unknown({Wrap, S}, V) when Wrap =:= optional; Wrap =:= nullable -> unknown(S, V);
unknown({default, S, _}, V) -> unknown(S, V);
unknown({refine, S, _}, V) -> unknown(S, V);
unknown({desc, _, S}, V) -> unknown(S, V);
unknown(_, _) -> [].

quote(K) when is_binary(K) -> muse_json:encode(K);
quote(K) -> muse_json:encode(iolist_to_binary(io_lib:format("~p", [K]))).

join(Msgs) -> iolist_to_binary(lists:join(<<"; ">>, Msgs)).
