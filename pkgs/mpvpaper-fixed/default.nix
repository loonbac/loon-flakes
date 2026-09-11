{ mpvpaper, fetchFromGitHub }:

# mpvpaper 1.8 no llamaba a mpv_render_context_report_swap(), por lo que
# libmpv 0.41 acumulaba fences OpenGL y memoria sin límite. La corrección fue
# integrada upstream en 1.9 (GhostNaN/mpvpaper#132).
mpvpaper.overrideAttrs (_old: rec {
  version = "1.9";

  src = fetchFromGitHub {
    owner = "GhostNaN";
    repo = "mpvpaper";
    rev = version;
    hash = "sha256-FpwMhzYmbjwvbpJd6xDRka6h2bvgsqdopqP5deQKXSA=";
  };
})
