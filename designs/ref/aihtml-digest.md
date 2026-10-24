# aihtml digest for beamai_muse (the whole web UI on aihtml)

Source: `david@192.168.3.13:/home/david/workspace/aihtml` @ `327668d` (2026-10-01, clean, in sync with
`origin/master` = `git@github.com:DavidAlphaFox/aihtml.git`). All signatures below were checked against
`apps/aihtml/src/*.erl`, `apps/aihtml/include/*.hrl`, `apps/aihtml_cowboy/src/*.erl`, and
`apps/aihtml/assets/js/runtime/*.ts`. The design docs (`designs/01..07`, in Chinese) and `README.en.md` are
accurate and worth reading. Start with `designs/02-actions.md` and `03-push.md`.

The mental model has four parts:
- **Server-rendered HTML.** Pages are built as Erlang element records and rendered by ordinary cowboy handlers.
- **Actions.** Each browser event is one stateless signed POST. The reply is a list of DOM ops, or an NDJSON
  stream of op batches when the action calls `flush/1`.
- **Push.** A page subscribes to signed topics over one SSE stream. Any process can `publish` the same DOM ops.
- **Behaviour.** Component behaviour comes from Stimulus controllers (`data-ah="name"`), loaded lazily. You can
  register your own controllers from a page script.

Requirements: OTP 27+ (it uses the `json` module). It depends on `beamai_render`, pinned by git ref.
`aihtml_cowboy` pins `cowboy 2.13.0` (hex).

---

## 1. Depending on it

### rebar.config (git_subdir; this is the documented way)
```erlang
{deps, [{aihtml, {git_subdir, "https://github.com/DavidAlphaFox/aihtml.git",
                  {ref, "327668dce2a0e3d9336b4ddd6c9a3e2de71024d3"}, "apps/aihtml"}},
        {aihtml_cowboy, {git_subdir, "https://github.com/DavidAlphaFox/aihtml.git",
                         {ref, "327668dce2a0e3d9336b4ddd6c9a3e2de71024d3"}, "apps/aihtml_cowboy"}}]}.
```
- Pin both apps to the **same** ref.
- In `beamai_muse.app.src` `applications`, list `aihtml` and `aihtml_cowboy`. The `aihtml` app must be running
  because it starts the `pg` scope `aihtml_push` and checks the secret at boot.

### Local path (same host, iterating on aihtml)
rebar3 has no `path` deps. Use `_checkouts` symlinks to the umbrella subdirs. Keep the deps entries as well,
because `_checkouts` wins over them:
```sh
mkdir -p _checkouts
ln -s /home/david/workspace/aihtml/apps/aihtml        _checkouts/aihtml
ln -s /home/david/workspace/aihtml/apps/aihtml_cowboy _checkouts/aihtml_cowboy
```
`beamai_render` and `cowboy` are still fetched from aihtml's own rebar.configs.

### Config
```erlang
{aihtml, [{secret, <<"...>= 32 random bytes, same on every node...">>},
          {default_locale, <<"zh">>}]}            %% optional; en | zh built in
```
If you leave the secret out, aihtml generates a random one per boot. That is dev-only: every restart makes the
tokens on already-open pages answer 403. A secret that is set but shorter than 32 bytes stops the aihtml app
from booting.

### Static assets (JS runtime + CSS)
- **Prebuilt files are shipped and committed.** `apps/aihtml/priv/static/js/` holds the Vite bundle (`main-<hash>.js`,
  one chunk per component, vendor chunks for echarts, xlsx and jspdf, and `.vite/manifest.json`).
  `priv/static/css/aihtml-<hash>.css` plus `css/manifest.json` hold the styles. Consumers never need npm for JS.
- **Serving.** `aihtml_cowboy:routes(#{})` already includes `"/aihtml/[...]" -> cowboy_static {priv_dir, aihtml, "static"}`,
  and `aihtml:page/2` points `<script type=module>` and the stylesheet at `/aihtml/` by default.
  To serve them elsewhere, use `routes(#{static => false})` plus your own route, and set
  `page(..., #{assets => <<"/static/ah/">>})`. aihtml sets no Cache-Control headers. The hashed files are
  immutable; the manifests are not.

### Tailwind: does the consumer need its own build?
- **The prebuilt `aihtml-<hash>.css` = all prefab styles + only the Tailwind utilities that the library's own
  `.erl` sources use** (`assets/aihtml.build.css`: `@source "../src"`).
- **What fails without a build:** any utility class you write in beamai_muse (`flex gap-3 max-w-4xl h-[70vh]`…)
  is absent unless the library happens to use it.
- **So for a real app, yes: run your own Tailwind v4 build.** It is only the Tailwind CLI, with no Vite and no JS
  build. The example app does exactly this (`apps/aihtml_example/assets/example.css`).

```css
/* beamai_muse/assets/muse.css */
@import "tailwindcss" source(none);
@import "../_build/default/lib/aihtml/apps/aihtml/priv/css/aihtml.css";   /* prefabs + 4-axis tokens */
@source "../_build/default/lib/aihtml/apps/aihtml/src";
@source "../src";
/* with _checkouts instead: ../_checkouts/aihtml/priv/css/aihtml.css and ../_checkouts/aihtml/src */
```
- **Build:** `npx @tailwindcss/cli -i assets/muse.css -o priv/static/css/muse.css --minify`. Optionally hash it
  the way the example does (copy `scripts/hash-css.mjs`, then read `manifest.json` in a `css/0` like
  `aihtml_example_site:css/0`).
- **Wiring:** pass `css => [<<"/static/css/muse-xxxx.css">>]` to `page/2`. The `css` option **replaces** the
  default stylesheet, and your build already contains the prefabs. Serve it with your own `cowboy_static` route.
- **Literal class names only.** Tailwind scans `.erl` literally, so never assemble class names at runtime.
- **Theme tokens.** Utilities such as `bg-primary`, `text-muted`, `border-line` and `rounded-control` follow the
  theme.

---

## 2. Page rendering, cowboy routing, layout, theming

```erlang
-include_lib("aihtml/include/aihtml.hrl").   %% imports every ah_* builder + all records
```
- **Builders:**
  - Plain tags: `ah_div/1,3`, `ah_p`, `ah_span`, `ah_ul`, `ah_li`, `ah_table`… `ah_form/1,3`, `ah_main`,
    `ah_nav`, `ah_aside`, `ah_header`, `ah_footer`, `ah_pre`, `ah_code`.
  - Void tags: `ah_img(Css, Attrs)`, `ah_hr/2`, `ah_br/0`.
  - Escape hatches: `ah_el(Tag, Children, Css, Attrs)` and `ah_void(Tag, Css, Attrs)` take **any** tag, e.g.
    `iframe`, `video`, `script`. `safe(IoData)` passes trusted raw HTML.
- **Css arg:** atoms are prefab modifiers, validated against `aihtml_catalog`. Binaries are literal or Tailwind
  classes.
- **Attrs:** a proplist or map. `aria_label` becomes `aria-label`, `{data, #{k=>v}}` becomes `data-k`, and
  `true`/`false` produce boolean attributes. Nested lists are allowed, so `on(...)`, `subscribe(...)` and
  `opens(...)` can be spliced in.
- **Record form:** `#ah_button{body=..., variant=primary, postback={save, Args}}` is checked at compile time.
  `postback` is shorthand for `on(PrimaryEvent, {?MODULE, Action, Args})`.

**Cowboy:**
```erlang
Dispatch = cowboy_router:compile([{'_',
    [{"/", muse_chat_page, #{}}, {"/login", muse_login, #{}}, ...]
    ++ aihtml_cowboy:routes(#{})                  %% /aihtml/action, /aihtml/events, /aihtml/[...]
    ++ [{"/static/[...]", cowboy_static, {priv_dir, beamai_muse, "static"}}]}]).

%% handler
init(Req, St) ->
    {ok, aihtml_cowboy:reply(Req, view(...), #{title => <<"Muse">>, css => [muse_css()],
                                              lang => <<"zh">>, theme => #{appearance => dark}}), St}.
```
- **`aihtml_cowboy:routes(opts())`** takes `#{action, events, static => boolean(), origins => [binary()]}`.
  The action and events endpoints accept same-origin requests only, plus anything in `origins`.
- **`aihtml_cowboy:reply(Req, Body, aihtml_page:opts()) -> Req`** always answers 200 `text/html`. Use
  `cowboy_req:reply/4` yourself for redirects.
- **`aihtml_page` opts:**
  - Basics: `title`, `lang`, `theme`, `persist` (restore the saved theme before first paint).
  - Assets: `assets`, `css`, `runtime`, `js` (extra deferred script URLs that run after the runtime, in order).
  - Markup: `head` (extra `<head>` html), `body_css`, `body_attrs`.
  - Endpoints: `action` and `events` (endpoint URLs).
  - SEO: `description`, `canonical`, `og`, `meta`, `json_ld`, and so on.
- **No layout concept.** Write your own `muse_layout:shell(Active, Content)`: sidenav + header + `ah_main`.
  The example's `aihtml_example_site:reply/4` and `topbar/1` are the pattern to copy.
- **Theming has four axes on `<html>`:**
  - `appearance`: light | dark | paper
  - `palette`: default, green, luxury, retro, arctic, nature, editorial, ember, dracula, midnight, brutal,
    brutal-blue, island, phoqus
  - `typography`: default | serif | grotesk
  - `skin`: default | brutal | island | phoqus

  Set them server-side with `theme => #{appearance => dark, palette => midnight}` and client-side with
  `AH.theme.set(Axis, V)`, which persists to localStorage. `ah_theme_switcher(Css, Attrs)` is a ready-made picker
  for the Settings page.
- **i18n.** zh and en are built in. The language comes from `page(..., #{lang => ...})`. Actions render in the
  page's language, available as `aihtml_action:lang(Ctx)`.

---

## 3. Actions

### Binding
```erlang
on(Event, {Module, Action, Args})                 %% -> attrs(), splice into Attrs
on(Event, {M, A, Args}, #{debounce => Ms, include => [Sel | {id, Id}], confirm => Prompt,
                          sync => drop | replace | queue, sync_scope => Sel,
                          indicator => Sel | this, disable => Sel | this})
on_client(Event, fun(C) -> aihtml_action:call(C, Target, open, []) end)   %% no request; ops baked into HTML
fetch(Method, Url, Target[, #{swap, trigger, confirm, indicator, disable}]) %% GET/POST your own URL, swap HTML
```
- **Events:**
  - Delegated DOM events: click, dblclick, change, input, submit, keydown, keyup, focusin, focusout,
    mouseenter, mouseleave.
  - Component events such as `'ah:close'`, `'ah:toggle'` and `'ah:edit'` are also accepted.
- **Args are signed, not encrypted.** Keep them to plain data such as ids. Tokens **never expire**, so you must
  re-check authorization inside every action.
- **The module must declare `-behaviour(aihtml_action)`** and export `action/4`.

### Callback
```erlang
-behaviour(aihtml_action).
-spec action(atom(), term(), aihtml_action:event(), aihtml_action:ctx()) -> any().
action(send, #{thread := T}, #{form := #{<<"prompt">> := P}}, Ctx) -> ...
```
The `Event` map is `#{type, id, value, checked, key, form := #{Name => Bin}, values := #{IdOrName => V}, data := #{k => Bin}}`:
- **`form`** holds every field of the enclosing `<form>`. Bind `on(submit, ...)` on the form.
- **`values`** holds the controls named by `include`.
- **`data`** holds the element's own `data-*` attributes, except those starting with `ah`.
- **`value`** prefers `data-ah-value` (custom components) over the native value. For multi-value components,
  split it with `aihtml_value:split/1`.
- **Not included:** mouse coordinates, modifier keys, and CustomEvent `detail` (see Gaps).

### DOM operations (`aihtml_action`, all `-> ok`, buffered and sent when the action returns)
| fun | effect |
|---|---|
| `html(Ctx, Target, Html)` / `html(Ctx, Target, Html, Swap)` | Swap is `inner` (default) \| `outer` \| `append` \| `prepend` \| `morph` \| `morph_inner`. Focus and caret are restored by id. |
| `remove(Ctx, Target)` | remove the element |
| `attr(Ctx, Target, Name, Value)` | `false` or `undefined` removes the attribute. Set `data-ah-value` to drive tabs, expander and progressbar. |
| `add_class/3`, `remove_class/3` | change classes |
| `set_value(Ctx, T, V)` | set a form value; booleans set a checkbox |
| `focus/2`, `title/2`, `redirect(Ctx, Url)` | focus an element, set the document title, navigate |
| `js(Ctx, Code)` | run JS with `AH` and the page globals in scope (never build it from user input) |
| `call(Ctx, Target \| global, Method, Args)` | call a component method, e.g. drawer `open`, chart `setData`, `global notify` |
| `trigger(Ctx, Target \| document, Event, Detail)` | fire a bubbling CustomEvent |
| `push_url/2`, `replace_url/2` | change history without a request; back/forward reload that URL |
| `flush(Ctx)` | send the buffered ops **now**, which turns the reply into an NDJSON stream (key for streaming, see §4) |
| `meta(Ctx)` | `#{req => cowboy_req:req()}` under aihtml_cowboy |
| `lang(Ctx)`, `stream_id(Ctx)` | the page language; the page's push stream id |

`Target` is a CSS selector binary or `{id, Id}`. Overlay helpers: `aihtml_lib_overlay:open/close/toggle(Ctx, Target)`,
`aihtml_toast:ah_toast(Ctx, Msg, #{variant, description, duration, position, closable})` and
`aihtml_notification:notify(Ctx, #{content, variant, duration, ...})`.

The reply is JSON `{"ops":[...]}`, or NDJSON lines after a flush. Errors are 403 `invalid_action`,
400 `bad_request` and 500 `action_failed`. Crashes are logged only, and the browser fires `ah:error` on the
element.

### Ctx, cookies, session, auth
- **The action runs in the cowboy request process.** Ctx only works there: the op buffer lives in the process
  dictionary.
- **Reading cookies works:**
  ```erlang
  #{req := Req} = aihtml_action:meta(Ctx),
  Sid = proplists:get_value(<<"muse_sid">>, cowboy_req:parse_cookies(Req)).
  ```
- **You cannot set a cookie or header from an action.** `aihtml_cowboy_action` builds the reply from its own
  `Req0`, so `cowboy_req:set_resp_cookie` inside an action is lost.
- **Login:** use a **native form POST** to your own `/login` cowboy handler. It verifies the access key, sets an
  HttpOnly cookie and replies with a 302 to `/`. `ah_form` without `on(submit, …)` submits natively; add
  `{action, <<"/login">>}, {method, post}`.
- **Logout:** a plain link or form to `/logout`, which clears the cookie. Or an action that does
  `redirect(Ctx, "/logout")`.
- **Page handlers** check the cookie and answer 302 to `/login`.
- **A shared guard** keeps the per-action check short:
  `with_user(Ctx, fun(User) -> ... end)`. When the session is missing it calls `redirect(Ctx, <<"/login">>)`.
- **SSE topics are authorised at render time.** Only render topics such as `{user, Uid}` for that user. The
  events endpoint has no auth hook (see Gaps).
- **CSRF:** Origin checks on both endpoints plus JSON-only bodies already cover actions. Your `/login` form POST
  needs its own Origin check; `aihtml_cowboy_action:origin_ok(Req, [])` is exported and reusable.

---

## 4. Server push and live updates

- **Mechanism:** SSE, not websocket. Each page opens **one EventSource**, to `GET /aihtml/events?t=Tok&t=Tok…`.
  It is handled by `aihtml_cowboy_events`, a `cowboy_loop` that joins `pg` groups.
- **Events:** `hello` (the stream id) first, then `ops` (the same op list as actions), plus a `: ping` every 25 s.
  `retry: 2000`.
- **Subscriptions follow the DOM.** When new HTML adds or removes `data-ah-subscribe` elements, the page POSTs
  the new topic set without reconnecting.
- **Limit:** at most 32 topics per page.
- **Delivery is at-most-once.** On reconnect, every `refresh` action on the page runs to catch up from the data
  layer.
- **Slow readers:** a stream with more than 1000 queued messages is dropped, then reconnects and refreshes.
- **Cluster-wide:** pg spans all connected nodes.

```erlang
%% render: subscribe an element (any term topic; one subscription per element)
ah_div(Msgs, [], [{id, <<"thread-42">>},
                  subscribe({thread, 42}, #{refresh => {?MODULE, refresh_thread, #{id => 42}}})])

%% any process, any node
aihtml_push:publish(Topic, fun(C) -> aihtml_action:html(C, {id, X}, Html, append) end).
aihtml_push:publish(Topic, Fun, #{except => Ctx | StreamIdBin, lang => <<"zh">>}).
aihtml_push:call(Topic, Target | global, Method, Args[, #{except => Ctx}]).
aihtml_push:trigger(Topic, Target | document, Event, Detail[, Opts]).
aihtml_push:subscribers(Topic) -> non_neg_integer().   %% e.g. only refresh screenshots while someone watches
```
- **`publish` renders once in the caller and fans out to subscribers.** Inside the fun you may use every
  `aihtml_action` op, plus `aihtml_toast:ah_toast(C, …)` and `aihtml_notification:notify(C, …)`. The last two
  are `call global notify` under the hood, which makes them the **notifications** channel: subscribe the layout
  to `{user, Uid}`.
- **`except => Ctx`** skips the page that caused the change, since it already updated through its action reply.

### Token-by-token streaming into a bubble: YES, two ways
**A. Push (recommended for durable runs, multi-tab, reconnect):**
- **Setup:** the chat page subscribes the message list to `{thread, Tid}`. The agent-run process, or a small
  relay process fed by beamai's internal events (no need to go over HTTP/AG-UI SSE), publishes deltas.
- **Text deltas:** for `TEXT_MESSAGE_CONTENT`, append the escaped text to the bubble's text span:
  `publish({thread,T}, fun(C) -> aihtml_action:html(C, {id, <<"m-", Mid/binary, "-txt">>}, Delta, append) end)`.
  A binary is rendered as escaped text, so `append` inserts a text node.
- **Batching:** coalesce deltas every 50–100 ms in the relay so you do not do one publish per token.
- **On message end:** re-render the bubble as `ah_markdown_view(FullText, …)` with `morph` or `outer`. During
  streaming, show the raw text in a `whitespace-pre-wrap` span. Alternatively, re-render the full markdown every
  N ms with `morph`, which is fine at chat sizes.
- **Tool results:** a `TOOL_CALL_RESULT` becomes `html(C, {id, MsgList}, tool_card(Result), append)`.
- **Reconnect:** the `refresh` action re-renders the thread from the store, which fixes any lost deltas.

**B. Long action with `flush/1` (NDJSON):**
- **How it works:** the "send" action starts the run, then loops on `receive` of deltas, doing
  `html(..., append)` and `flush(Ctx)` for each batch. Each flush is applied in the browser as it arrives
  (`fetch` + ReadableStream).
- **Where it fits:** single-tab, request-scoped flows such as **Computer → run command → stream output into a
  `<pre>`**.
- **Drawbacks:** it ends when the page navigates; while the action is in flight, the same element is
  `sync => drop` (a double submit is ignored, which is good); and the request holds a cowboy process. The demo's
  `loading/1` is the minimal example.

**Stop button:** a separate element and action: `on(click, {muse_chat, stop, #{run => Rid}})`. It tells the run
to stop (registry or data layer). The run's final publish then swaps the composer back from "Stop" to "Send".

---

## 5. Components relevant to beamai_muse
All of these come from `aihtml.hrl` (the facade). The signature is the function form; the record form is
`#ah_<name>{}` with the fields listed. Value components write `data-ah-value` and fire `change`.

| Need | Builder (verified spec) | Key options / record fields |
|---|---|---|
| App sidebar | `ah_sidenav(Groups \| Items, ActiveKey, Css, Attrs)` | `Groups = [#{label, items := [Item]}]`. `Item = {Key, Label}` \| `#{key, label, icon, href, children, disabled, divider}`. Options: `brand => #{name, logo, href}`, `footer`, `collapsible`, `collapsed`, `route_prefix` (generates hrefs). |
| Top bar | `ah_navbar(Items, ActiveKey, Css, Attrs)` | `brand`, `extra`, `orientation`, `minimized`. Also `ah_menu/4`, `ah_listmenu/4`, `ah_toolbar(Tools, Css, Attrs)`, `ah_breadcrumbs`. |
| Drawer / side sheet | `ah_drawer(Body, Css, Attrs)`, `ah_sheet(Body, Css, Attrs)` | `side` (top\|bottom\|left\|right), `title`, `description`, `footer`, `size`, `open`, `closable`. Open with `opens({id, Id})` or `aihtml_lib_overlay:open(Ctx, {id, Id})`. Postback fires on `ah:close`. |
| Dialog / modal | `ah_window(Body, Css, Attrs)` with `{modal, true}` | `title`, `footer`, `width`, `height`, `resizable`, `draggable`, `closable`. Buttons use `closes()` and `closes(closest, ok)`. There is no separate `dialog` component; `window` with modal is the dialog (see the demo `window_dialog`). |
| Card | `ah_card(Body, Css, Attrs)` | `title`, `subtitle`, `extra` (header-right slot for actions), `header`, `media`, `footer`. Flags: `hover`, `flush`. Also `ah_panel/3` and `ah_expander/3`. |
| Chips | `ah_chip(Content, Css, Attrs)` | `variant` filled\|outlined\|soft. `color` default\|primary\|success\|warning\|error\|info… `size` small\|medium. Also `removable`, `clickable`, `icon`, `avatar`, `value`. |
| Badge | `ah_badge(Body, Css, Attrs)` | `count`, `max`. `variant` standard\|dot\|online\|away\|busy\|offline. `color`. Corner badge on Body; standalone when Body is blank. Use a `chip` for status pills. |
| Tables | `ah_datatable(Columns, Rows, Css, Attrs)`, `ah_datagrid(Columns, Rows, Css, Attrs)` | Column: `field` or `{field, Title}` or `#{field, title, width, align, sortable, filterable, editable, type, render => fun(V, Row) -> html end, class, hidden}`. Rows are maps. Remote mode: `{source, {M, A, Args}}` + `datatable_query/1` / `datatable_rows/3`. Use for Documents, Monitors and Ideas lists. |
| Markdown | `ah_markdown_view(Markdown, Css, Attrs)` | Server-side markdown-it port. Raw HTML is treated as text; only safe links. `#ah_markdown_view{markdown = Md}`. Editor: `ah_markdown_editor(Md, Css, Attrs)` (ProseMirror). |
| Text input | `ah_input(Value, Css, Attrs)`, `ah_textarea(Value, Css, Attrs)`, `ah_password_input/3` | `id`, `attrs` and postback go to the **native control**. `size`, `state`, `label`, `disabled`. Input also has `prefix`, `suffix`, `clearable`. Validation: `validate([required, ...])`. Also `ah_field(Label, Control, Css, Attrs)`, `ah_form_layout/…`, `ah_tag_input/3`, `ah_switch_button/4` (settings toggles), `ah_select`, `ah_dropdownlist/4`. |
| Tabs | `ah_tabs([{Key, Label, Panel} \| {Key, Label, Panel, #{disabled}}], ActiveKey, Css, Attrs)` | `position`, `name`. Switch from the server by setting the `data-ah-value` attr. Also `ah_tab_bar/4` (tabs without panels) and `ah_segmented_control/4`. |
| Toast | `aihtml_toast:ah_toast(Ctx, Msg, #{variant, description, duration, position, closable})` | Can be pushed. Also `shows_toast(Msg, Opts)` (client-only trigger attrs). |
| Notification | `ah_notification(Body, Css, Attrs)` (a hidden template opened by id) + `aihtml_notification:notify(Ctx, #{content, variant, duration, ...})` | Variants: info\|success\|warning\|error. Options: `position`, `auto_close`, `delay`. |
| Alert | `ah_alert(Body, Css, Attrs)` | `variant`, `title`, `dismissible`, `icon`. Use for inline errors and "needs approval" banners. |
| Timeline | `ah_timeline([#{date, title, subtitle, icon, description, dot, expanded}], Css, Attrs)` | `dot` is primary\|success\|warning\|danger. `position` both\|near\|far, `horizontal`, `collapsible`. Use for the task timeline. |
| Steps | `ah_steps([Label \| {Label, Desc} \| map()], CurrentIdx0, Css, Attrs)` | `orientation`, `clickable`, `show_nav`. Use for plan steps and goal milestones. |
| Progress | `ah_progressbar(Value \| undefined, Css, Attrs)`, `ah_progress_circle/3`, `ah_meter/3` | `min`, `max`, `show_text`, `text`, `color`, `indeterminate`, `striped`, `animated`. Follows the `data-ah-value` attr, so pushing `attr(C, {id,P}, 'data-ah-value', 40)` updates it live. |
| Loader | `ah_loader(Css, Attrs)` | `text`, `inline`, `center`, `modal`, `hidden`. Also `ah_skeleton(Css, Attrs)`, and `ah-indicator` + `on(..., #{indicator => Sel})`. |
| Empty state | `ah_empty(Body, Css, Attrs)` | `title`, `description`, `icon`, `compact`. Body is the action area. |
| Avatar | `ah_avatar(Initials, Css, Attrs)` | `src`, `alt`, `size` sm\|md\|lg\|xl, `shape`, `color`. |
| Image | `ah_img(Css, [{src, Url}, {alt, ..}])` | Plain void tag. Use `ah_aspect_ratio(Body, Css, Attrs)` for a ratio box. |
| iframe | `ah_el(iframe, [], [<<"w-full h-[80vh]">>], [{src, <<"/docs/7/pdf">>}, {title, ..}])` | No prefab. Add `preserve()` + an id so swaps never reload it. |
| Misc | `ah_time_ago(TsOrDatetime, Css, Attrs)`, `ah_kpi_card/3`, `ah_statistic/3` (finance summary), `ah_expandable_text/3`, `ah_kbd/3`, `ah_tooltip`, `ah_popover`, `ah_tree/4` with lazy `set_children/3` (file browser), `ah_upload/3`, `ah_diff/…`, `ah_dropdown_button/4`, `ah_split_button/4` (Approve ▾ / Reject) | |

Snippets:
```erlang
%% shell
shell(Active, Content) ->
    ah_div([ah_sidenav([#{label => <<"Muse">>, items => [{chat, <<"Chat">>}, {activity, <<"Activity">>},
                                                          {goals, <<"Goals">>}, {monitors, <<"Monitors">>},
                                                          {ideas, <<"Ideas">>}, {documents, <<"Documents">>},
                                                          {computer, <<"Computer">>}, {browser, <<"Browser">>}]},
                        #{label => <<"Account">>, items => [{settings, <<"Settings">>}]}],
                       Active, [], [{route_prefix, <<"/">>}, {collapsible, true},
                                    {brand, #{name => <<"Muse">>}}]),
            ah_main(Content, [<<"flex-1 min-w-0 overflow-auto">>], [])],
           [<<"flex h-screen">>], [subscribe({user, uid()})]).        %% notifications/toasts channel

%% composer (Enter = submit via native form submit)
ah_form([ah_textarea(<<>>, [<<"flex-1">>], [{name, prompt}, {id, prompt}, {rows, 2}]),
         ah_button(<<"Send">>, send, [primary], [{type, submit}, {id, <<"send-btn">>}])],
        [<<"flex gap-2">>], [on(submit, {muse_chat, send, #{thread => T}})])

%% approval card (the result goes via each button's own action, not ah:close)
ah_card(ah_markdown_view(Summary, [], []), [],
        [{title, <<"Action review">>},
         {footer, [ah_button(<<"Approve">>, a, [success], [on(click, {muse_act, approve, #{id => Id}})]),
                   ah_button(<<"Reject">>, r, [error], [on(click, {muse_act, reject, #{id => Id}})])]}])

%% task row with live progress
ah_div([ah_strong(Title), ah_progressbar(Pct, [], [{id, <<"task-", Id/binary, "-p">>}, {show_text, true}]),
        ah_chip(Status, [soft], [{color, success}])],
       [], [{id, <<"task-", Id/binary>>}])   %% list subscribed to {activity, Uid}; publish morph per change
```

---

## 6. Gaps, workarounds, feature-request drafts

Escape hatches that exist today:
- **Custom element records:** `-include_lib("aihtml/include/aihtml_element.hrl")`, `-record(muse_x, {?AH_BASE(muse_x), ...})`,
  and implement the `-behaviour(aihtml_element)` callback `render/1`.
- **Custom Stimulus controllers:** a page script loaded via `page(…, #{js => [<<"/static/js/muse.js">>]})`
  (deferred, runs after the runtime) can call
  `AH.register("muse-term", class extends AH.Controller { setup(){…} teardown(){…} })`.
  The element gets `{data_ah, <<"muse-term">>}`. Server `call` ops then reach the controller's methods.
  `this.listen(target, type, handler)` auto-unbinds.
- **Client API:** `AH.apply(ops)`, `AH.swap(target, html, mode)`, `AH.morph(target, html)`.
- **Raw scripts:** `head => safe(...)`, `ah_el(script, safe(Js), [], [])`, or the `js(Ctx, Code)` op.

| # | Gap | Workaround now | Severity for muse |
|---|---|---|---|
| G1 | **No text-delta op.** Streaming uses `html(..., append)`, which works because binaries are escaped into text nodes, but every chunk goes through `insertAdjacentHTML`, settle classes and a mount check. Live markdown re-render is DIY. | Option A/B in §4: batch deltas and morph `ah_markdown_view` at the end. | 🟡 works, slightly wasteful |
| G2 | **The client cannot consume an external SSE / AG-UI stream.** `designs/02` *plans* an AG-UI client component (`CUSTOM name:"aihtml.ops"` → `AH.apply`) but it is not implemented (no AG-UI code in assets). | Consume beamai_agui events **server-side** in Erlang and relay through `aihtml_push`. Or write a page script doing `fetch`/`EventSource` → `AH.apply(ops)`. | 🟡 server relay is clean |
| G3 | **Actions cannot set cookies or response headers** (`aihtml_cowboy_action` replies with its own Req). | Native form POST to your own `/login` and `/logout` handlers. | 🟢 |
| G4 | **No auth hook on `/aihtml/events` and `/aihtml/action`.** Tokens and topic tokens never expire, so a logged-out tab keeps receiving pushes on topics it was rendered with. | Check the session in every action. Put a session or epoch in topics (`{user, Uid, Epoch}`) and rotate the epoch on logout. Or wrap the endpoints: route your own module that checks the cookie, then delegates to `aihtml_cowboy_events:init/2` / `aihtml_cowboy_action:init/2`. | 🟡 |
| G5 | **The event payload lacks mouse coordinates, modifier keys and CustomEvent `detail`.** For example, `closes(closest, ok)` → `ah:close` `{result}` never reaches the action. | Coordinates: a page script listener on the `<img>` (it runs before the document-delegated handler) sets `el.dataset.x/y` from `offsetX/offsetY` and the natural size; `data-*` is sent in `Event.data`. Modifiers: same trick (`dataset.mods`). Result: give each button its own `on(click, …)`. | 🔴 for the Browser console |
| G6 | **Keyboard capture is lossy.** `keydown` defaults to `sync => replace`, which aborts in-flight requests. `queue` keeps only the latest waiting request, so fast typing drops keys. There is no `preventDefault` for keydown, so Tab or Backspace also act on the page. | For the Browser console: a text input + "Type" button (send the whole string), buttons for special keys (Enter/Tab/Esc/Backspace/arrows), and a custom `muse-keys` controller that buffers keys and POSTs batches to your own JSON endpoint. | 🔴 for take-control |
| G7 | **No client-side timer or auto-refresh** (no "poll every N s" attribute). | Server: a per-console process does `aihtml_push:publish({browser, Sid}, fun(C) -> aihtml_action:attr(C, {id, shot}, src, Url ++ "?t=" ++ Ts) end)` every 2 s, but only while `aihtml_push:subscribers/1 > 0`. Or a tiny `muse-refresh` controller (`setInterval`, swaps `src`). Use `preserve()` to avoid flicker. | 🟢 |
| G8 | **File upload goes outside actions** (it is JSON-only). | `ah_upload([], [], [{url, <<"/upload">>}, on(change, {M, uploaded, #{}})])` + your own multipart handler (copy `aihtml_example_upload`). `uploaded_files(Event)` returns the list. | 🟢 |
| G9 | **No code editor or terminal emulator** (no CodeMirror, no xterm). | Terminal: `<pre>` + input form, with output streamed via `flush/1` (append). File editor: `ah_textarea` with `font-mono`, or a custom controller that loads CodeMirror from your static files. File browser: `ah_tree` with lazy `load`, or a datatable. | 🟡 |
| G10 | **No iframe or PDF prefab** (and no dialog component; modal window only). | `ah_el(iframe, …)` + `preserve()`. Serve the PDF from your own route with `content-type: application/pdf`. | 🟢 |
| G11 | **The prebuilt CSS only contains the library's own utilities.** | Your own Tailwind CLI build (§1). It needs Node at build time only. | 🟢 |
| G12 | **Push limits:** 32 topics per page; at-most-once delivery; a slow client is cut at 1000 queued messages. | Use per-user or per-thread topics, not per-task. Always provide `refresh`. Batch token deltas. | 🟢 |
| G13 | **No Enter-to-send / Shift+Enter newline handling on textarea**, because modifiers are not sent and there is no conditional preventDefault. | A `muse-composer` controller: on Enter without Shift, preventDefault and `form.requestSubmit()`. | 🟢 |

### Feedback convention
- **aihtml has no `feedbacks/` dir yet.** Searched: no `feedbacks/` and no mention of "feedback" in any aihtml
  `.md`.
- **Sibling repos use one** (`beamai_extra`, `keelson`, `keel`, `porthole`, `chartroom`, …):
  - The **upstream** repo hosts `feedbacks/README.md` (an index table) plus one file per item,
    `feedbacks/<YYYY-MM-DD>-<slug>.md`, filed by the downstream host.
  - It records **only things the upstream side should change**: the downstream either cannot work around them,
    or the workaround is clumsy. Downstream bugs stay out.
  - Each file follows the order: **症状** (what downstream sees, the exact line, or "silent") → **位置**
    (`file:line` upstream) → **怎么撞上的** (shortest repro) → **影响面** (who hits it, what happens, does it
    error) → **建议** (optional; downstream does not decide for the owner).
  - The README index columns are `# | 标题 | 报的人 | 严重度 (🔴/🟡/🟢) | 回没回`. There is also an optional
    "⭐ 先说做得好的几处" section.
- **For muse → aihtml:** create `aihtml/feedbacks/README.md` with that header and table, then one file per item
  below once we actually hit them while building (reporter: `beamai_muse`).

Drafts (in the convention's order):

1. **`<date>-event-payload-no-coords-mods-detail.md`** 🔴
   - **症状:** an action bound to `click` on an `<img>` gets no position. `keydown` gets `key` but not
     ctrl/shift/alt/meta. `on('ah:close', …)` never sees the `closes(closest, ok)` result.
   - **位置:** `assets/js/runtime/actions.ts` `#eventPayload` and `#onEvent` (`const ev = {type, key}`).
   - **影响面:** any "remote control" UI (browser take-control, canvas, image maps), and every component event
     that carries `detail`. Silent: the fields are simply missing.
   - **建议:** add `detail` (JSON-safe CustomEvent.detail); `mods: {ctrl, shift, alt, meta}`; and, for mouse
     events, `pointer: {x, y, w, h}` (offset plus element client size, or natural size for img).

2. **`<date>-keydown-lossy-no-preventdefault.md`** 🔴
   - **症状:** typing fast into an element bound to `on(keydown, …)` loses keys. `replace` aborts in-flight
     requests, and `queue` keeps only the latest. Tab, Backspace and Space also act on the page.
   - **位置:** `actions.ts` `LATEST_WINS` and `run()` queue semantics.
   - **建议:** a `sync => fifo` strategy that keeps all queued requests, or a `batch => Ms` option that sends the
     key sequence as a list. A `prevent_default => true` option for bound key events, optionally filtered by key.

3. **`<date>-text-append-op.md`** 🟡
   - **症状:** streaming LLM text has to use `html(…, append)` per chunk, which goes through
     `insertAdjacentHTML`, settle classes and the mount scan.
   - **建议:** a `text` op `{op:"text", id, value, mode: append|replace}` that does `textContent` / `appendData`,
     plus `aihtml_action:text/3,4`. Optionally a `markdown_view` method `appendMarkdown`, which re-renders
     client-side or via a server morph.

4. **`<date>-agui-client-component.md`** 🟡
   - **症状:** `designs/02-actions.md` §「与 AG-UI 的关系」 promises an AG-UI client component that applies
     `CUSTOM aihtml.ops`. It does not exist. A chat page cannot consume a beamai_agui run stream directly.
   - **建议:** a behaviour `agui-stream` (data-url, thread id, Last-Event-ID resume) that renders
     TEXT_MESSAGE_* into a target and applies `CUSTOM aihtml.ops`; or document the server-relay pattern as the
     official answer.

5. **`<date>-endpoint-auth-hook.md`** 🟡
   - **症状:** `/aihtml/events` and `/aihtml/action` cannot reject a request whose session cookie is gone. Push
     and action tokens never expire.
   - **位置:** `aihtml_cowboy:routes/1`, `aihtml_cowboy_events:open/2`.
   - **建议:** a `routes(#{authorize => fun((Req) -> ok | {deny, Status})})` option checked before verify/join,
     and/or an optional `max_age` on tokens.

6. **`<date>-action-cannot-set-response-headers.md`** 🟢
   - **症状:** `cowboy_req:set_resp_cookie` in an action has no effect.
   - **建议:** let the action return or update a Req via `aihtml_action:set_meta/2`, or let the transport apply
     `resp_cookies` and `resp_headers` collected in meta before replying. Otherwise, document "use a plain form
     POST for login".

7. **`<date>-auto-refresh-attr.md`** 🟢 (nice to have)
   - **建议:** `poll(Ms, {M, A, Args})` attrs (htmx `every Ns`), so periodic refresh needs neither a server
     timer nor a custom script.

---

## 7. Suggested beamai_muse page → mechanism map
| Page | Mechanism |
|---|---|
| Login | Native `ah_form` POST to `/login` (your handler) → HttpOnly cookie → 302 |
| Chat | Thread list subscribed to `{thread, T}` + refresh. Send = `on(submit)` action that starts the run. A relay publishes deltas (append) and a final morph to markdown_view. Stop = action. Tool cards = custom `muse_card_*` render funs (card + markdown_view / datatable / img / iframe / steps / statistic). |
| Activity | `ah_datatable` or a list subscribed to `{activity, Uid}`. Task detail uses `ah_timeline` + `ah_progressbar` (data-ah-value). Pause/resume/cancel/retry are button actions with `confirm`. Approvals: card + Approve/Reject actions; the toast is pushed. |
| Goals / Ideas / Monitors | Datatable + sheet/drawer forms (`ah_sheet` with `opens`). Milestones use `ah_steps`. |
| Documents | Datatable of PDFs → `ah_el(iframe, …)` on `/documents/:id/pdf`; upload via `ah_upload` + `/upload` |
| Computer | Terminal: form → long action, `flush/1` streams into `<pre>`. Files: `ah_tree` (lazy) + `ah_textarea` editor + save action. |
| Browser console | `<img id=shot>` refreshed by a server push every 2 s while subscribers > 0. A custom script adds coordinates to dataset (G5). Typing: an input + key buttons (G6). |
| Settings / Memories | `ah_form_layout` / `ah_field` + `ah_switch_button`, `ah_theme_switcher`, datatable of memories with delete |
| Notifications | Layout root subscribed to `{user, Uid}`. Publish `ah_toast` / `notify`, and badge counts via `html`/`attr` ops. |
