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

# `grouped` is shared by every style, so a person filed under two sections is
# drawn twice by all eleven of them — and the base class is what has to keep
# that from costing a second copy of their avatar in the file.
describe "every style with a multi-section user" do
  ContributorMural::Style.each do |style|
    it "draws #{style} once per section from one copy of the face" do
      config = ContributorMural::Config.parse(<<-YAML)
        style: #{style.to_s.downcase}
        sort: none
        groups: [Core, Thanks]
        users:
          - login: alpha
            group: Core
            also_in: [Thanks]
          - login: bravo
            group: Core
          - login: carol
            group: Thanks
        stencil:
          text: HI
        YAML

      users = ContributorMural::Resolver.resolve(config)
      renderer = ContributorMural::Renderer.for(config.style, config)
      renderer.prepare(users)
      embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
        .embed(users, renderer, fail_on_missing: false)
      groups = ContributorMural::Resolver.grouped(embedded, config)
      svg = renderer.render(groups)

      # Three people, one of them drawn twice: four drawings, three faces.
      svg.scan(%r{<a href="https://github.com/alpha"}).size.should eq(2)
      svg.scan(/data:image\/png;base64,/).size.should eq(3)
      svg.scan(/<symbol id="mural-face-/).size.should eq(1)
      svg.scan(/<use href="#mural-face-1"/).size.should eq(2)
      # And a second render of the same document comes out the same, which is
      # what `reset_document` is for and what the shared faces must not break.
      renderer.render(groups).should eq(svg)
    end
  end
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

  describe "#render" do
    # Several styles carry state across a document: section ordinals that salt
    # the jitter, a colour cycle, generated clip-path ids, a cached pack. All of
    # it has to be cleared before the next document, or a renderer used twice
    # draws a different picture the second time — which is what the action does
    # when one config names several outputs in the same style.
    #
    # Checked over every style rather than the five that hold state today, so a
    # style that starts holding some cannot quietly skip the reset.
    it "draws the same document every time the renderer is reused" do
      config = config_for(<<-YAML)
        groups: [core, friends]
        users:
          - login: alpha
            group: core
            weight: 9
            role: maintainer
          - login: bravo
            group: core
            weight: 4
          - login: charlie
            group: friends
            weight: 2
          - login: delta
            group: friends
            weight: 1
        YAML

      ContributorMural::Style.each do |style|
        renderer = ContributorMural::Renderer.for(style, config)
        users = ContributorMural::Resolver.resolve(config)
        renderer.prepare(users)
        embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
          .embed(users, renderer, fail_on_missing: false)
        groups = ContributorMural::Resolver.grouped(embedded, config)

        first = renderer.render(groups)
        renderer.render(groups).should eq(first), style.to_s
      end
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
