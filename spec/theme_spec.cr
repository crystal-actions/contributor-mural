require "./spec_helper"
require "./support/fake_avatar_source"

private def theme_from(yaml : String) : ContributorMural::ThemeConfig
  ContributorMural::Config.parse(yaml).theme
end

private def render_with(yaml : String) : String
  config = ContributorMural::Config.parse(yaml)
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(embedded)
end

describe ContributorMural::ThemeConfig do
  it "resolves preset palettes" do
    theme = theme_from("theme:\n  preset: midnight\nusers:\n  - login: x")
    theme.light_palette.background.should eq("#0b1021")
    theme.dark_palette.title_color.should eq("#dfe6f3")
  end

  it "applies flat overrides to the light palette and dark overrides to the dark one" do
    theme = theme_from(<<-YAML)
      theme:
        label_color: "#111111"
        dark:
          label_color: "#eeeeee"
      users:
        - login: x
      YAML

    theme.light_palette.label_color.should eq("#111111")
    theme.light_palette.background.should eq("transparent")
    theme.dark_palette.label_color.should eq("#eeeeee")
  end

  it "rejects unknown presets" do
    config = ContributorMural::Config.parse("theme:\n  preset: vaporwave\nusers:\n  - login: x")
    expect_raises(ContributorMural::ConfigError, /unknown theme `preset`/) { config.validate! }
  end

  it "rejects colors that could escape the style block" do
    config = ContributorMural::Config.parse(<<-YAML)
      theme:
        label_color: "red}.x{fill:blue"
      users:
        - login: x
      YAML

    expect_raises(ContributorMural::ConfigError, /unsafe characters/) { config.validate! }
  end
end

describe "theme rendering modes" do
  it "auto mode emits a prefers-color-scheme style block" do
    svg = render_with("users:\n  - login: x")
    svg.should contain("<style>")
    svg.should contain("@media (prefers-color-scheme:dark)")
    svg.should contain(".mural-label{fill:#57606a}")
    svg.should contain(%(class="mural-label"))
    svg.should_not contain(%(fill="#57606a"))
  end

  it "light mode inlines fills without a style block" do
    svg = render_with("theme:\n  mode: light\nusers:\n  - login: x")
    svg.should_not contain("<style>")
    svg.should contain(%(fill="#57606a"))
  end

  it "dark mode inlines the dark palette" do
    svg = render_with("theme:\n  mode: dark\nusers:\n  - login: x")
    svg.should_not contain("<style>")
    svg.should contain(%(fill="#8b949e"))
  end

  it "skips the background rect when both palettes are transparent" do
    svg = render_with("users:\n  - login: x")
    svg.should_not contain("<rect class=\"mural-bg\"")
  end

  it "draws the background rect when a preset sets one" do
    svg = render_with("theme:\n  preset: midnight\nusers:\n  - login: x")
    svg.should contain(%(.mural-bg{fill:#0b1021}))
    svg.should contain(%(<rect class="mural-bg"))
  end
end
