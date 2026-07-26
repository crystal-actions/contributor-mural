require "./spec_helper"

private INPUT_VARS = %w[INPUT_CONFIG INPUT_TOKEN INPUT_NO_COMMIT INPUT_COMMIT_MESSAGE
  GITHUB_WORKSPACE GITHUB_TOKEN GITHUB_ACTIONS]

private def with_clean_env(vars : Hash(String, String), &)
  saved = INPUT_VARS.to_h { |name| {name, ENV[name]?} }
  INPUT_VARS.each { |name| ENV.delete(name) }
  vars.each { |name, value| ENV[name] = value }
  yield
ensure
  saved.try &.each do |name, value|
    value ? (ENV[name] = value) : ENV.delete(name)
  end
end

describe ContributorMural::Inputs do
  it "uses CLI values and defaults outside of actions" do
    with_clean_env({} of String => String) do
      inputs = ContributorMural::Inputs.resolve("conf.yml", "/tmp/ws", false)
      inputs.config_path.should eq("conf.yml")
      inputs.workspace.should eq("/tmp/ws")
      inputs.token.should be_nil
      inputs.commit?.should be_false
      inputs.commit_message.should eq(ContributorMural::Inputs::DEFAULT_COMMIT_MESSAGE)
    end
  end

  it "lets INPUT_* env vars win over CLI values" do
    env = {
      "INPUT_CONFIG"         => "action.yml",
      "GITHUB_WORKSPACE"     => "/github/workspace",
      "INPUT_TOKEN"          => "tok",
      "INPUT_COMMIT_MESSAGE" => "custom",
      "GITHUB_ACTIONS"       => "true",
    }
    with_clean_env(env) do
      inputs = ContributorMural::Inputs.resolve("conf.yml", "/tmp/ws", false)
      inputs.config_path.should eq("action.yml")
      inputs.workspace.should eq("/github/workspace")
      inputs.token.should eq("tok")
      inputs.commit_message.should eq("custom")
      inputs.commit?.should be_true
    end
  end

  it "respects no_commit inside actions" do
    env = {"GITHUB_ACTIONS" => "true", "INPUT_NO_COMMIT" => "true"}
    with_clean_env(env) do
      ContributorMural::Inputs.resolve.commit?.should be_false
    end
  end

  it "commits locally only with the explicit flag" do
    with_clean_env({} of String => String) do
      ContributorMural::Inputs.resolve(commit_flag: true).commit?.should be_true
      ContributorMural::Inputs.resolve.commit?.should be_false
    end
  end

  it "falls back to GITHUB_TOKEN" do
    with_clean_env({"GITHUB_TOKEN" => "ghtok"}) do
      ContributorMural::Inputs.resolve.token.should eq("ghtok")
    end
  end
end
