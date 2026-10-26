%% @doc Inline SVG icons for the UI (Lucide shapes, ISC licence), as aihtml
%% `{safe, _}` markup. They take the text colour (`stroke: currentColor`)
%% and are hidden from assistive technology; the element around an icon
%% carries the label.
-module(muse_ui_icons).

-export([icon/1, icon/2]).

-spec icon(atom()) -> {safe, iodata()}.
icon(Name) ->
    icon(Name, 18).

-spec icon(atom(), pos_integer()) -> {safe, iodata()}.
icon(Name, Size) ->
    S = integer_to_binary(Size),
    {safe, [<<"<svg class=\"muse-icon\" width=\"">>, S, <<"\" height=\"">>, S,
            <<"\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" "
              "stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">">>,
            paths(Name), <<"</svg>">>]}.

paths(menu) -> <<"<path d=\"M4 6h16M4 12h16M4 18h16\"/>">>;
paths(bell) -> <<"<path d=\"M10.3 21a1.94 1.94 0 0 0 3.4 0\"/><path d=\"M3.26 15.33A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.67C19.41 13.96 18 12.5 18 8A6 6 0 0 0 6 8c0 4.5-1.41 5.96-2.74 7.33\"/>">>;
paths(plus) -> <<"<path d=\"M12 5v14M5 12h14\"/>">>;
paths(arrow_up) -> <<"<path d=\"m5 12 7-7 7 7\"/><path d=\"M12 19V5\"/>">>;
paths(stop) -> <<"<rect x=\"6\" y=\"6\" width=\"12\" height=\"12\" rx=\"2\"/>">>;
paths(search) -> <<"<circle cx=\"11\" cy=\"11\" r=\"7\"/><path d=\"m20 20-3.5-3.5\"/>">>;
paths(globe) -> <<"<circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"M2 12h20\"/><path d=\"M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z\"/>">>;
paths(terminal) -> <<"<path d=\"m4 17 6-6-6-6\"/><path d=\"M12 19h8\"/>">>;
paths(monitor) -> <<"<rect x=\"2\" y=\"3\" width=\"20\" height=\"14\" rx=\"2\"/><path d=\"M8 21h8M12 17v4\"/>">>;
paths(mail) -> <<"<rect x=\"2\" y=\"4\" width=\"20\" height=\"16\" rx=\"2\"/><path d=\"m22 7-10 6L2 7\"/>">>;
paths(calendar) -> <<"<rect x=\"3\" y=\"4\" width=\"18\" height=\"18\" rx=\"2\"/><path d=\"M16 2v4M8 2v4M3 10h18\"/>">>;
paths(file) -> <<"<path d=\"M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z\"/><path d=\"M14 2v4a2 2 0 0 0 2 2h4\"/>">>;
paths(tasks) -> <<"<rect x=\"3\" y=\"3\" width=\"18\" height=\"18\" rx=\"2\"/><path d=\"M3 9h18M9 21V9\"/>">>;
paths(settings) -> <<"<path d=\"M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/>">>;
paths(chat) -> <<"<path d=\"M7.9 20A9 9 0 1 0 4 16.1L2 22z\"/>">>;
paths(brain) -> <<"<path d=\"M12 5a3 3 0 1 0-5.997.125 4 4 0 0 0-2.526 5.77 4 4 0 0 0 .556 6.588A4 4 0 1 0 12 18Z\"/><path d=\"M12 5a3 3 0 1 1 5.997.125 4 4 0 0 1 2.526 5.77 4 4 0 0 1-.556 6.588A4 4 0 1 1 12 18Z\"/>">>;
paths(check) -> <<"<path d=\"M20 6 9 17l-5-5\"/>">>;
paths(x) -> <<"<path d=\"M18 6 6 18M6 6l12 12\"/>">>;
paths(alert) -> <<"<circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"M12 8v4M12 16h.01\"/>">>;
paths(chevron_right) -> <<"<path d=\"m9 18 6-6-6-6\"/>">>;
paths(chevron_left) -> <<"<path d=\"m15 18-6-6 6-6\"/>">>;
paths(sparkles) -> <<"<path d=\"M9.94 14.06 8.5 19l-1.44-4.94L2 12.5l5.06-1.44L8.5 6l1.44 5.06L15 12.5z\"/><path d=\"M19 3v4M17 5h4\"/>">>;
paths(logout) -> <<"<path d=\"M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4\"/><path d=\"m16 17 5-5-5-5M21 12H9\"/>">>;
paths(archive) -> <<"<rect x=\"2\" y=\"3\" width=\"20\" height=\"5\" rx=\"1\"/><path d=\"M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8M10 12h4\"/>">>;
paths(pencil) -> <<"<path d=\"M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z\"/>">>;
paths(tool) -> <<"<path d=\"M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z\"/>">>.
