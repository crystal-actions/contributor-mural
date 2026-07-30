require "./spec_helper"

describe ContributorMural::Annotations do
  around_each do |example|
    io = IO::Memory.new
    ContributorMural::Annotations.io = io
    example.run
  ensure
    ContributorMural::Annotations.io = STDOUT
  end

  it "emits error annotations with file and line" do
    ContributorMural::Annotations.error("boom", file: "conf.yml", line: 3)
    ContributorMural::Annotations.io.to_s.should eq("::error file=conf.yml,line=3::boom\n")
  end

  it "emits plain warnings" do
    ContributorMural::Annotations.warning("careful")
    ContributorMural::Annotations.io.to_s.should eq("::warning::careful\n")
  end

  it "escapes newlines and percent signs in messages" do
    ContributorMural::Annotations.error("a%b\nc")
    ContributorMural::Annotations.io.to_s.should eq("::error::a%25b%0Ac\n")
  end

  it "escapes colons and commas in properties" do
    ContributorMural::Annotations.error("x", file: "a:b,c.yml")
    ContributorMural::Annotations.io.to_s.should eq("::error file=a%3Ab%2Cc.yml::x\n")
  end

  it "writes step outputs to GITHUB_OUTPUT" do
    path = File.tempname("gh_output")
    begin
      ENV["GITHUB_OUTPUT"] = path
      ContributorMural::Annotations.output("svg_path", "CONTRIBUTOR_MURAL.svg")
      ContributorMural::Annotations.output("user_count", "7")
      File.read(path).should eq("svg_path=CONTRIBUTOR_MURAL.svg\nuser_count=7\n")
    ensure
      ENV.delete("GITHUB_OUTPUT")
      File.delete?(path)
    end
  end

  it "ignores step outputs outside of GitHub Actions" do
    ENV.delete("GITHUB_OUTPUT")
    ContributorMural::Annotations.output("k", "v")
  end

  # The outputs are written after the mural already is, so an unwritable
  # GITHUB_OUTPUT used to throw away finished work with a stack trace.
  it "warns rather than raises when GITHUB_OUTPUT cannot be written" do
    ENV["GITHUB_OUTPUT"] = File.join(File.tempname("missing_dir"), "out.txt")
    begin
      ContributorMural::Annotations.output("paths", "wall.svg")
      ContributorMural::Annotations.io.to_s.should contain("::warning::could not write the `paths` step output")
    ensure
      ENV.delete("GITHUB_OUTPUT")
    end
  end
end
