%% @doc Tool definitions for beamai agents with zod-like validation
%% (designs/03-agent.md §2).
%%
%% `define/5` takes a muse_validate object schema and produces a beamai tool
%% spec: the schema becomes beamai's parameter DSL for the model, and the
%% handler receives arguments that were validated and normalised (trim,
%% defaults, limits) exactly like the zod schemas of OpenMuse.
%%
%% Handlers: `fun(Args :: map(), Ctx) -> {ok, Result} | {ok, Result, StateWrites}
%% | {error, Message}`. Invalid arguments, `{error, Msg}`, thrown task errors
%% and crashes are returned to the model as `{"error": Msg}` (OpenMuse tools
%% report failures as data). A lost lease also becomes an error result, as in
%% OpenMuse's task tool wrapper: the tool runs in its own process, and the
%% run itself notices the lost lease at its next guard or checkpoint.
%%
%% Options: `serial` (default true; keeps checkpoints in call order),
%% `timeout` (ms), `return_direct`, `link_run` (link the handler process to
%% the run pid in state slot `run_pid`, so cancelling the run kills
%% long-running tools such as commands, browsing and search).
-module(muse_tool).

-export([define/4, define/5, params/1, state/2]).

-type handler() :: fun((map(), term()) -> {ok, term()} | {ok, term(), map()} | {error, binary()}).

-spec define(binary(), binary(), muse_validate:schema(), handler()) -> map().
define(Name, Description, Schema, Fun) ->
    define(Name, Description, Schema, Fun, #{}).

-spec define(binary(), binary(), muse_validate:schema(), handler(), map()) -> map().
define(Name, Description, Schema, Fun, Opts) ->
    Handler = fun(Args, Ctx) -> call(Name, Schema, Fun, Opts, Args, Ctx) end,
    Spec = #{name => Name,
             description => Description,
             parameters => params(Schema),
             handler => Handler,
             serial => maps:get(serial, Opts, true)},
    maps:merge(Spec, maps:with([timeout, return_direct], Opts)).

%% @doc A context state slot (binary keys), e.g. `<<"owner">>`, `<<"task_id">>`.
-spec state(term(), binary()) -> term().
state(Ctx, Key) ->
    beamai_context:state_get(Ctx, Key).

%% @doc beamai parameter DSL for an object schema.
-spec params(muse_validate:schema()) -> map().
params({object, Fields}) ->
    maps:from_list([{Key, field(S)} || {Key, S} <- Fields]);
params({refine, S, _}) ->
    params(S);
params({desc, _, S}) ->
    params(S).

%% Internal

call(Name, Schema, Fun, Opts, Args, Ctx) ->
    maybe_link(Opts, Ctx),
    case muse_validate:check(Schema, Args) of
        {error, Msgs} ->
            {ok, #{<<"error">> => iolist_to_binary(lists:join(<<"; ">>, Msgs))}};
        {ok, Valid} ->
            try Fun(Valid, Ctx) of
                {ok, _} = Ok -> Ok;
                {ok, _, Writes} = Ok when is_map(Writes) -> Ok;
                {error, Msg} -> {ok, #{<<"error">> => message(Msg)}};
                Other -> {ok, Other}
            catch
                throw:{lost_lease, _} ->
                    {ok, #{<<"error">> => <<"Task was paused, cancelled or taken over by another worker">>}};
                throw:{task_failed, Msg} -> {ok, #{<<"error">> => Msg}};
                Class:Reason:St ->
                    logger:warning("tool ~ts crashed: ~p:~p ~p", [Name, Class, Reason, St]),
                    {ok, #{<<"error">> => <<Name/binary, " failed">>}}
            end
    end.

maybe_link(#{link_run := true}, Ctx) ->
    case catch beamai_context:state_get(Ctx, <<"run_pid">>) of
        Pid when is_pid(Pid) -> link(Pid);
        _ -> ok
    end;
maybe_link(_, _) ->
    ok.

message(Msg) when is_binary(Msg) -> Msg;
message({Status, Msg}) when is_integer(Status), is_binary(Msg) -> Msg;
message({outcome_unknown, Msg}) when is_binary(Msg) -> Msg;
message({internal, Msg}) when is_binary(Msg) -> Msg;
message(Other) ->
    logger:warning("[OpenMuse] tool error: ~0p", [case Other of
                                                      T when is_tuple(T), tuple_size(T) > 0 -> element(1, T);
                                                      A -> A
                                                  end]),
    <<"The tool failed">>.

field(S) ->
    {Spec, Required} = describe(S, undefined, true),
    Spec#{required => Required}.

describe({desc, Text, S}, _, Req) -> describe(S, Text, Req);
describe({optional, S}, D, _) -> describe(S, D, false);
describe({default, S, _}, D, _) -> describe(S, D, false);
describe({nullable, S}, D, Req) -> describe(S, D, Req);
describe({refine, S, _}, D, Req) -> describe(S, D, Req);
describe(S, D, Req) -> {with_desc(base(S), D), Req}.

with_desc(Spec, undefined) -> Spec;
with_desc(Spec, D) -> Spec#{description => D}.

base({string, #{enum := E}}) -> #{type => string, enum => E};
base({string, _}) -> #{type => string};
base({enum, E}) -> #{type => string, enum => E};
base({literal, L}) when is_binary(L) -> #{type => string, enum => [L]};
base({integer, _}) -> #{type => integer};
base({number, _}) -> #{type => float};
base(boolean) -> #{type => boolean};
base({array, Item, _}) -> #{type => array, items => element(1, describe(Item, undefined, true))};
base({object, Fields}) -> #{type => object, properties => params({object, Fields})};
base({record, _, _}) -> #{type => object};
base({union, [First | _]}) -> base(First);
base({tagged, _, _}) -> #{type => object};
base(any) -> #{type => object};
base({desc, _, S}) -> base(S);
base({optional, S}) -> base(S);
base({default, S, _}) -> base(S);
base({nullable, S}) -> base(S);
base({refine, S, _}) -> base(S).
