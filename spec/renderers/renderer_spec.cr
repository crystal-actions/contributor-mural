require "../spec_helper"
require "../support/fake_avatar_source"

# The dispatch and capability tables every style is reached through. Each style
# has its own spec for what it draws; what is only checked here is that the
# tables stay in step with the `Style` enum — a style added to the enum and
# forgotten in one of these is a run that draws the wrong picture, or a
# `scale:` silently ignored with no warning.

private def config_for(yaml : String = "users:\n  - login: alpha") : ContributorMural::Config
  ContributorMural::Config.parse(yaml)
end

private def render_grid(config : ContributorMural::Config, mode : ContributorMural::ThemeMode?) : String
  renderer = ContributorMural::Renderer.for(ContributorMural::Style::Grid, config, mode)
  users = ContributorMural::Resolver.resolve(config)
  renderer.prepare(users)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(embedded)
end

describe ContributorMural::Renderer do
  describe ".for" do
    it "builds the renderer named after each style" do
      config = config_for
      ContributorMural::Style.each do |style|
        renderer = ContributorMural::Renderer.for(style, config)
        renderer.class.name.should eq("ContributorMural::Renderers::#{style}")
      end
    end

    # The per-output `mode:` override is how one config writes a light and a
    # dark file, so it has to reach the renderer rather than the config's own
    # theme mode.
    it "passes the theme mode override through to the renderer" do
      config = config_for("theme:\n  mode: auto\nusers:\n  - login: alpha")

      auto = render_grid(config, nil)
      light = render_grid(config, ContributorMural::ThemeMode::Light)
      dark = render_grid(config, ContributorMural::ThemeMode::Dark)

      # Auto emits a <style> block for prefers-color-scheme; a forced mode
      # inlines the fills of the palette it was handed instead.
      auto.should contain("@media (prefers-color-scheme:dark)")
      light.should_not contain("<style>")
      dark.should_not contain("<style>")
      light.should contain(%(fill="#57606a"))
      dark.should contain(%(fill="#8b949e"))
    end
  end

  describe ".honors_scale?" do
    # The styles that derive a size per user, where an override is exact.
    it "is true for the styles that size each avatar for themselves" do
      {ContributorMural::Style::Mosaic, ContributorMural::Style::Spiral,
       ContributorMural::Style::Orbit, ContributorMural::Style::Constellation,
       ContributorMural::Style::Skyline, ContributorMural::Style::Pebble}.each do |style|
        ContributorMural::Renderer.honors_scale?(style).should be_true, style.to_s
      end
    end

    # The fixed lattices have nowhere to put an oversized avatar, and voronoi
    # sizes cells by cutting the block up rather than by placing a shape.
    it "is false for the styles that cannot place an oversized avatar" do
      {ContributorMural::Style::Grid, ContributorMural::Style::Honeycomb,
       ContributorMural::Style::Stencil, ContributorMural::Style::Metro,
       ContributorMural::Style::Voronoi}.each do |style|
        ContributorMural::Renderer.honors_scale?(style).should be_false, style.to_s
      end
    end

    # Split exhaustively, so a new style has to be classified rather than
    # defaulting into the silent half.
    it "classifies every style" do
      honoring = ContributorMural::Style.values.count { |style| ContributorMural::Renderer.honors_scale?(style) }
      honoring.should eq(6)
      ContributorMural::Style.values.size.should eq(11)
    end
  end
end
