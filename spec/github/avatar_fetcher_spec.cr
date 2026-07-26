require "file_utils"
require "../spec_helper"
require "http/server"

# Boots a throwaway local HTTP server for redirect/error behavior. No external
# network is touched.
private def with_test_server(&)
  requests = [] of String
  server = HTTP::Server.new do |context|
    path = context.request.path
    requests << path
    case path
    when "/ok.png"
      context.response.content_type = "image/jpeg"
      context.response.print "JPEGDATA"
    when "/redirect"
      context.response.status_code = 301
      context.response.headers["Location"] = "/ok.png"
    when "/relative-redirect"
      context.response.status_code = 302
      context.response.headers["Location"] = "ok.png"
    when "/loop"
      context.response.status_code = 302
      context.response.headers["Location"] = "/loop"
    when "/bad-mime"
      context.response.headers["Content-Type"] = "@@@"
      context.response.print "DATA"
    when "/html"
      context.response.content_type = "text/html"
      context.response.print "<b>nope</b>"
    when "/redirect-internal"
      context.response.status_code = 302
      context.response.headers["Location"] = "https://127.0.0.1/secret.png"
    when "/missing"
      context.response.status_code = 404
    when "/flaky"
      if requests.count("/flaky") < 3
        context.response.status_code = 500
      else
        context.response.content_type = "image/png"
        context.response.print "RECOVERED"
      end
    else
      context.response.status_code = 500
    end
  end
  address = server.bind_unused_port "127.0.0.1"
  spawn { server.listen }
  begin
    yield "http://#{address}", requests
  ensure
    server.close
  end
end

private def user_with(avatar_url : String) : ContributorMural::ResolvedUser
  ContributorMural::ResolvedUser.new("tester", avatar_url: avatar_url)
end

describe ContributorMural::HTTPAvatarSource do
  describe "#url_for" do
    it "appends the size to explicit avatar URLs" do
      source = ContributorMural::HTTPAvatarSource.new
      source.url_for(user_with("https://example.com/a.png"), 128)
        .should eq("https://example.com/a.png?s=128")
      source.url_for(user_with("https://example.com/a.png?v=4"), 128)
        .should eq("https://example.com/a.png?v=4&s=128")
    end

    it "derives the GitHub avatar URL from the login" do
      source = ContributorMural::HTTPAvatarSource.new
      user = ContributorMural::ResolvedUser.new("hahwul")
      source.url_for(user, 128).should eq("https://github.com/hahwul.png?size=128")
    end
  end

  describe "local avatars" do
    it "reads workspace-relative files with extension-based content types" do
      workspace = File.tempname("mural_avatars")
      Dir.mkdir_p(File.join(workspace, "assets"))
      File.write(File.join(workspace, "assets/logo.webp"), "WEBPDATA")
      begin
        source = ContributorMural::HTTPAvatarSource.new(workspace)
        user = user_with("assets/logo.webp")
        source.url_for(user, 64).should eq("file:assets/logo.webp")
        bytes, content_type = source.fetch(user, 64)
        String.new(bytes).should eq("WEBPDATA")
        content_type.should eq("image/webp")
      ensure
        FileUtils.rm_rf(workspace)
      end
    end

    it "fails like a 404 when the file is missing" do
      source = ContributorMural::HTTPAvatarSource.new(File.tempname("mural_nowhere"))
      error = expect_raises(ContributorMural::AvatarError, /not found/) do
        source.fetch(user_with("assets/gone.png"), 64)
      end
      error.status.should eq(404)
    end

    it "rejects unsupported extensions" do
      expect_raises(ContributorMural::AvatarError, /unsupported local avatar type/) do
        ContributorMural::HTTPAvatarSource.new.fetch(user_with("assets/logo.bmp"), 64)
      end
    end

    it "refuses symlinks pointing outside the workspace" do
      workspace = File.tempname("mural_symlink")
      outside = File.tempname("mural_outside")
      Dir.mkdir_p(File.join(workspace, "assets"))
      File.write(outside, "SECRET")
      File.symlink(outside, File.join(workspace, "assets/logo.png"))
      begin
        expect_raises(ContributorMural::AvatarError, /escapes the repository/) do
          ContributorMural::HTTPAvatarSource.new(workspace).fetch(user_with("assets/logo.png"), 64)
        end
      ensure
        FileUtils.rm_rf(workspace)
        File.delete?(outside)
      end
    end

    it "turns unreadable files into AvatarError instead of crashing the fiber" do
      workspace = File.tempname("mural_perm")
      Dir.mkdir_p(File.join(workspace, "assets"))
      path = File.join(workspace, "assets/logo.png")
      File.write(path, "x")
      File.chmod(path, 0o000)
      begin
        expect_raises(ContributorMural::AvatarError, /could not be read/) do
          ContributorMural::HTTPAvatarSource.new(workspace).fetch(user_with("assets/logo.png"), 64)
        end
      ensure
        File.chmod(path, 0o644) rescue nil
        FileUtils.rm_rf(workspace)
      end
    end
  end

  describe "#fetch" do
    it "returns bytes and content type" do
      with_test_server do |base, _requests|
        source = ContributorMural::HTTPAvatarSource.new(backoff_base: 0.seconds)
        bytes, content_type = source.fetch(user_with("#{base}/ok.png"), 64)
        String.new(bytes).should eq("JPEGDATA")
        content_type.should eq("image/jpeg")
      end
    end

    it "follows absolute and relative redirects" do
      with_test_server do |base, _requests|
        source = ContributorMural::HTTPAvatarSource.new(backoff_base: 0.seconds, allow_local_redirects: true)
        bytes, _ = source.fetch(user_with("#{base}/redirect"), 64)
        String.new(bytes).should eq("JPEGDATA")

        bytes, _ = source.fetch(user_with("#{base}/relative-redirect"), 64)
        String.new(bytes).should eq("JPEGDATA")
      end
    end

    it "gives up on redirect loops" do
      with_test_server do |base, _requests|
        source = ContributorMural::HTTPAvatarSource.new(backoff_base: 0.seconds, allow_local_redirects: true)
        expect_raises(ContributorMural::AvatarError, /too many redirects/) do
          source.fetch(user_with("#{base}/loop"), 64)
        end
      end
    end

    it "does not retry a 404" do
      with_test_server do |base, requests|
        source = ContributorMural::HTTPAvatarSource.new(backoff_base: 0.seconds)
        error = expect_raises(ContributorMural::AvatarError, /404/) do
          source.fetch(user_with("#{base}/missing"), 64)
        end
        error.status.should eq(404)
        requests.count("/missing").should eq(1)
      end
    end

    it "falls back to image/png for malformed or non-image content types" do
      with_test_server do |base, _requests|
        source = ContributorMural::HTTPAvatarSource.new(backoff_base: 0.seconds)
        # `@@@` makes MIME parsing raise; `text/html` is simply not an image.
        _, content_type = source.fetch(user_with("#{base}/bad-mime"), 64)
        content_type.should eq("image/png")
        _, content_type = source.fetch(user_with("#{base}/html"), 64)
        content_type.should eq("image/png")
      end
    end

    it "refuses redirects that leave https or target internal addresses" do
      with_test_server do |base, _requests|
        source = ContributorMural::HTTPAvatarSource.new(backoff_base: 0.seconds)
        expect_raises(ContributorMural::AvatarError, /non-https avatar redirect/) do
          source.fetch(user_with("#{base}/redirect"), 64)
        end
        expect_raises(ContributorMural::AvatarError, /internal address/) do
          source.fetch(user_with("#{base}/redirect-internal"), 64)
        end
      end
    end

    it "retries server errors and succeeds" do
      with_test_server do |base, requests|
        source = ContributorMural::HTTPAvatarSource.new(backoff_base: 0.seconds)
        bytes, _ = source.fetch(user_with("#{base}/flaky"), 64)
        String.new(bytes).should eq("RECOVERED")
        requests.count("/flaky").should eq(3)
      end
    end
  end
end
