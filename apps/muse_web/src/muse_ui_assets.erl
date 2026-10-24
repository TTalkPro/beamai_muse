%% @doc URLs of the UI's own static assets with a content hash in the query,
%% so a rebuilt stylesheet or script is never served stale.
-module(muse_ui_assets).

-export([css/0, js/0]).

-spec css() -> binary().
css() -> url(<<"css/muse.css">>).

-spec js() -> binary().
js() -> url(<<"js/muse.js">>).

url(Rel) ->
    Path = filename:join([code:priv_dir(muse_web), "static", Rel]),
    Version = case file:read_file_info(Path, [{time, posix}]) of
                  {ok, Info} ->
                      Key = {?MODULE, Rel, element(6, Info), element(2, Info)},
                      case persistent_term:get(Key, undefined) of
                          undefined ->
                              {ok, Bin} = file:read_file(Path),
                              V = binary:part(muse_ids:sha256hex(Bin), 0, 10),
                              persistent_term:put(Key, V),
                              V;
                          V -> V
                      end;
                  {error, _} -> <<"0">>
              end,
    <<"/static/", Rel/binary, "?v=", Version/binary>>.
