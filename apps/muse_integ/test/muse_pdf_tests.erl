%% Port of OpenMuse tests/pdf.test.ts against muse_pdf + the Node sidecar.
%% Odd PDFs (encrypted, XFA, actions, dropdown, malformed /V) are built here
%% as small uncompressed classic PDFs instead of with pdf-lib.
-module(muse_pdf_tests).
-include_lib("eunit/include/eunit.hrl").

-define(INVALID, <<"Invalid PDF: expected nonempty PDF bytes up to 10 MiB">>).

%% Fixture

pdf_test_() ->
    case sidecar_available() of
        {false, Why} ->
            ?debugFmt("SKIPPING muse_pdf tests: ~s", [Why]),
            [];
        true ->
            {setup, fun start/0, fun stop/1,
             [{"sample has two pages and six blank fields", fun sample_fields/0},
              {"generated sample matches the bundled one", fun generate_sample/0},
              {"fill round-trips text and checkbox", fun fill_round_trip/0},
              {"fill rejects unknown names and wrong types", fun fill_rejects/0},
              {"text values are capped at 10000 characters", fun too_long/0},
              {"characters outside WinAnsi fail to render", fun font_error/0},
              {"invalid bytes are rejected before the port", fun precheck/0},
              {"garbage after a PDF header is malformed", fun garbage/0},
              {"encrypted PDFs are rejected", fun encrypted/0},
              {"XFA forms are rejected", fun xfa/0},
              {"page count must be 1..500", fun no_pages/0},
              {"unsupported fields are disclosed, not filled", fun dropdown/0},
              {"malformed text values fail inspection", fun malformed_value/0},
              {"actions are stripped from filled output", fun strips_actions/0},
              {"concurrent requests share the pool", fun concurrent/0},
              {"a wedged helper times out with 502", {timeout, 30, fun timeout/0}}]}
    end.

sidecar_available() ->
    Script = filename:join([muse_pdf:root(), "sidecars", "pdf"]),
    case {os:find_executable("node"),
          filelib:is_dir(filename:join(Script, "node_modules/pdf-lib"))} of
        {false, _} -> {false, "node is not on PATH"};
        {_, false} -> {false, "run `npm ci` in " ++ Script};
        _ -> true
    end.

start() ->
    {ok, Pid} = muse_pdf:start_link(),
    unlink(Pid),
    Pid.

stop(_Pid) ->
    case whereis(muse_pdf) of
        undefined -> ok;
        Pid -> stop_server(Pid)
    end.

stop_server(Pid) ->
    gen_server:stop(Pid).

sample() ->
    {ok, Bin} = muse_pdf:sample(),
    Bin.

fields(Pdf) ->
    {ok, #{<<"fields">> := Fields}} = muse_pdf:inspect(Pdf),
    maps:from_list([{N, {T, V}} || #{<<"name">> := N, <<"type">> := T, <<"value">> := V} <- Fields]).

%% Cases

sample_fields() ->
    Pdf = sample(),
    ?assertMatch(<<"%PDF-", _/binary>>, Pdf),
    {ok, #{<<"pageCount">> := 2, <<"fields">> := Fields}} = muse_pdf:inspect(Pdf),
    ?assertEqual(
       [#{<<"name">> => N, <<"value">> => <<>>, <<"type">> => <<"text">>}
        || N <- [<<"participant_name">>, <<"guardian_name">>, <<"emergency_contact">>,
                 <<"emergency_phone">>, <<"additional_notes">>]]
       ++ [#{<<"name">> => <<"permission_granted">>, <<"value">> => <<"false">>,
             <<"type">> => <<"checkbox">>}],
       Fields).

generate_sample() ->
    {ok, Fresh} = muse_pdf:generate_sample(),
    ?assertEqual(muse_pdf:inspect(sample()), muse_pdf:inspect(Fresh)).

fill_round_trip() ->
    Source = sample(),
    {ok, Filled} = muse_pdf:fill(Source, #{<<"participant_name">> => <<"Test Participant">>,
                                           <<"guardian_name">> => <<"Test Guardian">>,
                                           <<"permission_granted">> => true}),
    ?assertNotEqual(Source, Filled),
    ?assertEqual(Source, sample()),
    F = fields(Filled),
    ?assertEqual({<<"text">>, <<"Test Participant">>}, maps:get(<<"participant_name">>, F)),
    ?assertEqual({<<"text">>, <<"Test Guardian">>}, maps:get(<<"guardian_name">>, F)),
    ?assertEqual({<<"checkbox">>, <<"true">>}, maps:get(<<"permission_granted">>, F)),
    ?assertEqual({<<"text">>, <<>>}, maps:get(<<"participant_name">>, fields(Source))),
    {ok, Cleared} = muse_pdf:fill(Filled, #{<<"permission_granted">> => false}),
    ?assertEqual({<<"checkbox">>, <<"false">>}, maps:get(<<"permission_granted">>, fields(Cleared))),
    ?assertEqual({<<"text">>, <<"Test Participant">>}, maps:get(<<"participant_name">>, fields(Cleared))),
    %% Non-ASCII WinAnsi text renders with Helvetica.
    {ok, Accented} = muse_pdf:fill(Source, #{<<"participant_name">> => <<"Zoë Müller"/utf8>>}),
    ?assertEqual({<<"text">>, <<"Zoë Müller"/utf8>>}, maps:get(<<"participant_name">>, fields(Accented))).

fill_rejects() ->
    S = sample(),
    ?assertEqual({error, {422, <<"Unknown PDF field: missing">>}},
                 muse_pdf:fill(S, #{<<"missing">> => <<"value">>})),
    ?assertEqual({error, {422, <<"PDF checkbox requires a boolean: permission_granted">>}},
                 muse_pdf:fill(S, #{<<"permission_granted">> => <<"yes">>})),
    ?assertEqual({error, {422, <<"PDF text field requires a string: participant_name">>}},
                 muse_pdf:fill(S, #{<<"participant_name">> => true})),
    ?assertMatch({ok, _}, muse_pdf:fill(S, #{})).

too_long() ->
    S = sample(),
    ?assertEqual({error, {422, <<"PDF text field value is too long: additional_notes">>}},
                 muse_pdf:fill(S, #{<<"additional_notes">> => binary:copy(<<"a">>, 10001)})),
    {ok, Filled} = muse_pdf:fill(S, #{<<"additional_notes">> => binary:copy(<<"a">>, 10000)}),
    ?assertMatch({<<"text">>, <<"aaaa", _/binary>>}, maps:get(<<"additional_notes">>, fields(Filled))).

font_error() ->
    ?assertEqual({error, {422, <<"Could not render PDF field values; use characters supported "
                                 "by this form's font or choose a compatible PDF form">>}},
                 muse_pdf:fill(sample(), #{<<"participant_name">> => <<"漢字"/utf8>>})).

precheck() ->
    Big = <<"%PDF-1.7\n", (binary:copy(<<0>>, 10485760))/binary>>,
    Late = <<(binary:copy(<<" ">>, 1024))/binary, "%PDF-1.7\n">>,
    [?assertEqual({error, {422, ?INVALID}}, muse_pdf:inspect(B))
     || B <- [<<>>, <<"not a PDF">>, Big, Late]],
    ?assertEqual({error, {422, ?INVALID}}, muse_pdf:fill(<<"not a PDF">>, #{})),
    ?assertEqual({error, {422, ?INVALID}}, muse_pdf:fill(Big, #{})).

garbage() ->
    ?assertEqual({error, {422, <<"Invalid or malformed PDF">>}},
                 muse_pdf:inspect(<<"%PDF-1.7\nthis is not a pdf body\n">>)),
    ?assertEqual({error, {422, <<"Invalid or malformed PDF">>}},
                 muse_pdf:fill(<<"%PDF-1.7\n">>, #{})).

encrypted() ->
    Pdf = form_pdf(#{trailer => <<"/Encrypt 7 0 R">>,
                     extra => [<<"<< /Filter /Standard /V 1 >>">>]}),
    ?assertEqual({error, {422, <<"Encrypted PDFs are not supported">>}}, muse_pdf:inspect(Pdf)),
    ?assertEqual({error, {422, <<"Encrypted PDFs are not supported">>}},
                 muse_pdf:fill(Pdf, #{<<"name">> => <<"x">>})).

xfa() ->
    Pdf = form_pdf(#{acroform => <<"/XFA (<synthetic-xfa />)">>}),
    ?assertEqual({error, {422, <<"Unsupported XFA PDF form">>}}, muse_pdf:inspect(Pdf)),
    ?assertEqual({error, {422, <<"Unsupported XFA PDF form">>}},
                 muse_pdf:fill(Pdf, #{<<"name">> => <<"x">>})).

no_pages() ->
    Pdf = build([<<"<< /Type /Catalog /Pages 2 0 R >>">>,
                 <<"<< /Type /Pages /Kids [] /Count 0 >>">>], <<>>),
    ?assertEqual({error, {422, <<"PDF must contain between 1 and 500 pages">>}},
                 muse_pdf:inspect(Pdf)).

dropdown() ->
    Pdf = form_pdf(#{field => <<"/FT /Ch /Ff 131072 /T (visit_type) /Opt [(Museum) (Garden)] "
                                "/V (Museum)">>}),
    ?assertMatch({ok, #{<<"pageCount">> := 1,
                        <<"fields">> := [#{<<"name">> := <<"visit_type">>, <<"value">> := <<"Museum">>,
                                           <<"type">> := <<"unsupported">>}]}},
                 muse_pdf:inspect(Pdf)),
    ?assertEqual({error, {422, <<"Unsupported PDF field: visit_type">>}},
                 muse_pdf:fill(Pdf, #{<<"visit_type">> => <<"Garden">>})).

malformed_value() ->
    Pdf = form_pdf(#{field => <<"/FT /Tx /T (name) /V [(invalid)]">>}),
    ?assertEqual({error, {422, <<"Cannot inspect PDF: a text field contains a malformed value">>}},
                 muse_pdf:inspect(Pdf)).

strips_actions() ->
    Pdf = form_pdf(#{}),
    Markers = [<<"/OpenAction">>, <<"/AA">>, <<"/JS">>, <<"app.alert">>],
    [?assertNotEqual(nomatch, binary:match(Pdf, M)) || M <- Markers],
    {ok, Filled} = muse_pdf:fill(Pdf, #{<<"name">> => <<"Test Participant">>}),
    ?assertEqual({<<"text">>, <<"Test Participant">>}, maps:get(<<"name">>, fields(Filled))),
    Plain = plain_text(Filled),
    [?assertEqual({M, nomatch}, {M, binary:match(Plain, M)}) || M <- [<<"/A ">> | Markers]],
    ?assertNotEqual(nomatch, binary:match(Plain, <<"/Helvetica">>)).

concurrent() ->
    S = sample(),
    Self = self(),
    Pids = [spawn_link(fun() -> Self ! {self(), muse_pdf:inspect(S)} end) || _ <- lists:seq(1, 6)],
    [receive {P, R} -> ?assertMatch({ok, #{<<"pageCount">> := 2}}, R) end || P <- Pids].

timeout() ->
    Old = persistent_term:get({muse_config, config}, #{}),
    stop_server(whereis(muse_pdf)),
    application:set_env(muse_integ, pdf_timeout, 300),
    muse_config:set(Old#{pdf_sidecar => <<"sleep 60">>}),
    try
        {ok, Pid} = muse_pdf:start_link(),
        unlink(Pid),
        T0 = erlang:monotonic_time(millisecond),
        ?assertEqual({error, {502, <<"PDF helper timed out">>}}, muse_pdf:inspect(sample())),
        ?assert(erlang:monotonic_time(millisecond) - T0 < 5000),
        %% The slot is respawned for the next call.
        ?assertEqual({error, {502, <<"PDF helper timed out">>}}, muse_pdf:inspect(sample())),
        muse_config:set(Old#{pdf_sidecar => <<"/nonexistent/helper">>}),
        stop_server(Pid),
        {ok, Pid2} = muse_pdf:start_link(),
        unlink(Pid2),
        ?assertEqual({error, {502, <<"PDF helper is unavailable">>}}, muse_pdf:inspect(sample()))
    after
        application:unset_env(muse_integ, pdf_timeout),
        muse_config:set(Old)
    end.

%% Fixture PDFs

%% One page with one form field (default: text field `name' with a
%% JavaScript keystroke action) and a JavaScript OpenAction on the catalog.
form_pdf(Opts) ->
    AcroExtra = maps:get(acroform, Opts, <<>>),
    Field = maps:get(field, Opts, <<"/FT /Tx /T (name) /V (x) /AA << /K 6 0 R >> /A 6 0 R">>),
    build([<<"<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R /OpenAction 6 0 R >>">>,
           <<"<< /Type /Pages /Kids [3 0 R] /Count 1 >>">>,
           <<"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>">>,
           <<"<< /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) ", AcroExtra/binary, " >>">>,
           <<"<< /Type /Annot /Subtype /Widget /Rect [50 700 300 730] /P 3 0 R ",
             Field/binary, " >>">>,
           <<"<< /S /JavaScript /JS (app.alert\\('untrusted'\\);) >>">>
           | maps:get(extra, Opts, [])],
          maps:get(trailer, Opts, <<>>)).

%% Classic PDF with a correct xref table; objects are numbered from 1.
build(Objects, TrailerExtra) ->
    Header = <<"%PDF-1.7\n">>,
    {Body, Offsets, _} =
        lists:foldl(
          fun(Obj, {Acc, Offs, N}) ->
                  Off = byte_size(Header) + byte_size(Acc),
                  Text = <<(integer_to_binary(N))/binary, " 0 obj\n", Obj/binary, "\nendobj\n">>,
                  {<<Acc/binary, Text/binary>>, [Off | Offs], N + 1}
          end, {<<>>, [], 1}, Objects),
    XrefAt = byte_size(Header) + byte_size(Body),
    Size = length(Objects) + 1,
    Entries = [io_lib:format("~10..0B 00000 n \n", [O]) || O <- lists:reverse(Offsets)],
    iolist_to_binary(
      [Header, Body,
       "xref\n0 ", integer_to_binary(Size), "\n0000000000 65535 f \n", Entries,
       "trailer\n<< /Size ", integer_to_binary(Size), " /Root 1 0 R ", TrailerExtra, " >>\n",
       "startxref\n", integer_to_binary(XrefAt), "\n%%EOF\n"]).

%% The PDF with every Flate stream inflated in place, so dictionary keys
%% inside object streams become searchable.
plain_text(Pdf) ->
    {match, Streams} = re:run(Pdf, <<"stream\r?\n(.*?)\r?\nendstream">>,
                              [global, dotall, {capture, all_but_first, binary}]),
    iolist_to_binary([Pdf | [inflate(S) || [S] <- Streams]]).

inflate(S) ->
    try zlib:uncompress(S) catch error:_ -> <<>> end.
