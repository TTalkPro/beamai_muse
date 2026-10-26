%% @doc The user's workspace in sample or live mode (OpenMuse workspace.ts,
%% integrations spec §4) without mail and calendar: documents, browser
%% sessions, reviews and activity.
%%
%% Sample mode seeds the field-trip permission slip into Files once per
%% owner (`ensure_sample/1`), so the document demo runs end to end without a
%% model. Mail and calendar will come back as built-in features; until then
%% the snapshot carries neither.
-module(muse_workspace).

-export([ensure_sample/1, snapshot/1, section_snapshot/2]).

-type owner() :: binary().
-type error() :: {error, {pos_integer(), binary()}}.

-define(SAMPLE_PDF, <<"Field trip permission slip.pdf">>).
-define(SAMPLE_SOURCE, <<"Sample · Lincoln Middle School"/utf8>>).

%% @doc Seed the sample permission slip into Files (sample mode only, once
%% per owner).
-spec ensure_sample(owner()) -> ok | error().
ensure_sample(Owner) ->
    case mode() of
        live -> ok;
        sample ->
            global:trans({{?MODULE, seed, Owner}, self()},
                         fun() ->
                             case muse_store:get(Owner, <<"settings">>, <<"seeded">>) of
                                 undefined -> seed(Owner);
                                 _ -> ok
                             end
                         end, [node()], infinity)
    end.

seed(Owner) ->
    maybe
        {ok, Pdf} ?= muse_pdf:sample(),
        {ok, _} ?= muse_files:import(Owner, ?SAMPLE_PDF, Pdf, ?SAMPLE_SOURCE),
        _ = muse_store:put(Owner, <<"settings">>, #{<<"id">> => <<"seeded">>, <<"value">> => true}),
        ok
    else
        {error, {_, _}} = Error -> Error;
        {error, Reason} -> error({sample_seed_failed, Reason})
    end.

%% @doc OpenMuse Workspace snapshot (spec §2.5 / §4.4) without `mail` and
%% `events`, minus browser decoration, which the HTTP layer adds.
-spec snapshot(owner()) -> {ok, map()}.
snapshot(Owner) ->
    Mode = mode(),
    Config = muse_config:all(),
    {ok, #{<<"mode">> => atom_to_binary(Mode),
           <<"profile">> => #{<<"name">> => case Mode of sample -> <<"Alex">>; live -> <<"You">> end,
                              <<"email">> => <<>>},
           <<"files">> => muse_files:list(Owner),
           <<"browsers">> => muse_store:list(Owner, <<"browsers">>),
           <<"actions">> => muse_store:list(Owner, <<"actions">>),
           <<"activity">> => muse_store:list(Owner, <<"activity">>),
           <<"connections">> =>
               [#{<<"id">> => <<"browser">>, <<"name">> => <<"Browser">>,
                  <<"status">> => case muse_config:browser_configured() of
                                      true -> <<"connected">>;
                                      false -> <<"unconfigured">>
                                  end,
                  <<"capabilities">> => [<<"Persistent sessions">>, <<"PDF downloads">>]},
                #{<<"id">> => <<"openbot">>, <<"name">> => <<"OpenBot">>,
                  <<"status">> => <<"unconfigured">>,
                  <<"capabilities">> => [<<"Integration adapter available">>]}],
           <<"runtime">> => #{<<"provider">> => case maps:get(agent_backend, Config) of
                                                    sample -> <<"sample">>;
                                                    _ -> <<"model">>
                                                end,
                              <<"configured">> => muse_config:agent_configured(),
                              <<"openbotConfigured">> => false,
                              <<"richThreads">> => true}}}.

%% @doc `read_workspace` tool payload: the files, without URLs. Every
%% section (`files`, `all`) reads the same sources now that mail and
%% calendar are gone.
-spec section_snapshot(owner(), binary()) -> {ok, map()}.
section_snapshot(Owner, _Section) ->
    {ok, #{<<"files">> => muse_files:list(Owner, unsigned)}}.

mode() ->
    muse_config:get(mode).
