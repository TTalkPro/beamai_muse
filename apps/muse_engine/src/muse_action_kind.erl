%% @doc A kind of reviewed external write, plugged into muse_actions
%% (designs/02-engine.md §5).
%%
%% A kind module describes one `kind` of proposal: the schema of its
%% `data`, how the review card shows it and how an approved proposal is
%% executed. Kinds are registered at runtime with
%% `muse_actions:register_kind/2`. muse_engine's start registers the
%% built-in calendar's `calendar.event` (muse_calendar_action) and the
%% built-in mail's `mail.send` (muse_mail_action).
%%
%% Callbacks:
%% - `schema/0`: the muse_validate schema of `data` (an object schema, so
%%   the proposal hash follows its key order).
%% - `display/1`: the review card for validated `data`: its `title` (also
%%   stored on the proposal) and `fields`, `{Label, Value}` lines shown in
%%   order (empty values are skipped).
%% - `execute/3`: perform the approved write. `Review` holds the `target`
%%   and `target_version` returned by `prepare/2`, if any. Returns the
%%   receipt text, `{error, {outcome_unknown, Msg}}` when the write may have
%%   happened (never retried) or `{error, {Status, Msg}}` when it did not.
%% - `prepare/2` (optional): check `data` against the owner's state before
%%   review (for example that attachments exist) and capture the reviewed
%%   `target` and its `target_version`; both go into the hash, so a change
%%   to the target invalidates the review. Defaults to `{ok, #{data => Data}}`.
%% - `tool/0` (optional): `#{name, description}` of a task-model tool that
%%   proposes this kind (muse_task_model adds one per registered kind).
-module(muse_action_kind).

-export_type([display/0, review/0, tool/0]).

-type display() :: #{title := binary(), fields := [{binary(), binary()}]}.
-type review() :: #{target => map(), target_version => binary()}.
-type tool() :: #{name := binary(), description := binary()}.

-callback schema() -> muse_validate:schema().
-callback display(Data :: map()) -> display().
-callback execute(Owner :: binary(), Data :: map(), Review :: review()) ->
    {ok, Receipt :: binary()} | {error, {pos_integer() | outcome_unknown | internal, binary()}}.
-callback prepare(Owner :: binary(), Data :: map()) ->
    {ok, #{data := map(), target => map(), target_version => binary()}} | {error, {pos_integer(), binary()}}.
-callback tool() -> tool().

-optional_callbacks([prepare/2, tool/0]).
