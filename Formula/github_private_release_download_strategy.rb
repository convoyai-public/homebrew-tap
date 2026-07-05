# frozen_string_literal: true

# Downloads a GitHub release asset from a private repository.
#
# Background: the plain `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`
# URL that GoReleaser's `brews` pipe generates 404s unconditionally for a private repo, no
# matter what `Authorization`/`headers` are attached to that request -- that's simply not
# how GitHub authenticates access to private release assets over that host. Homebrew used
# to ship a `GitHubPrivateRepositoryReleaseDownloadStrategy` class that handled this, but it
# was removed years ago (Homebrew/brew#5573) with no replacement, so taps that need it have
# to vendor their own.
#
# The mechanism that actually works (verified against a real private repo):
#   1. Resolve the release's asset list via the JSON API
#      (`GET /repos/<owner>/<repo>/releases/tags/<tag>`) to find the numeric asset id for
#      the requested filename.
#   2. Download via `GET /repos/<owner>/<repo>/releases/assets/<id>` with
#      `Accept: application/octet-stream`, which 302-redirects to a signed, unauthenticated
#      blob URL (release-assets.githubusercontent.com) that curl follows with no further
#      auth needed.
#
# Requires a GitHub token with read access to the private repository, resolved via
# `GitHub::API.credentials` -- in practice `HOMEBREW_GITHUB_API_TOKEN`, but that helper
# also falls back to `gh auth token` and the macOS Keychain.
class GitHubPrivateReleaseDownloadStrategy < CurlDownloadStrategy
  URL_PATTERN = %r{\Ahttps://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)\z}.freeze
  private_constant :URL_PATTERN

  def initialize(url, name, version, **meta)
    super

    match = url.match(URL_PATTERN)
    unless match
      raise CurlDownloadStrategyError.new(url,
                                           "GitHubPrivateReleaseDownloadStrategy only supports " \
                                           "github.com/<owner>/<repo>/releases/download/<tag>/<file> URLs")
    end

    _, @owner, @repo, @tag, @filename = *match
  end

  private

  def _fetch(url:, resolved_url:, timeout:)
    token = GitHub::API.credentials
    if token.blank?
      raise CurlDownloadStrategyError.new(url,
                                           "Set HOMEBREW_GITHUB_API_TOKEN (or run `gh auth login`) to a token " \
                                           "with read access to #{@owner}/#{@repo} before installing")
    end

    release_url = "#{GitHub::API_URL}/repos/#{@owner}/#{@repo}/releases/tags/#{@tag}"
    ohai "Resolving release asset id for #{@owner}/#{@repo}@#{@tag}"
    result = curl_output(
      "--location",
      "--header", "Authorization: Bearer #{token}",
      "--header", "Accept: application/vnd.github+json",
      release_url,
      timeout: timeout,
      secrets: [token],
    )
    unless result.status.success?
      raise CurlDownloadStrategyError.new(url,
                                           "Failed to look up release metadata for #{@owner}/#{@repo}@#{@tag}: " \
                                           "#{result.stderr.strip}")
    end

    release = JSON.parse(result.stdout)
    asset = release.fetch("assets", []).find { |a| a["name"] == @filename }
    unless asset
      raise CurlDownloadStrategyError.new(url,
                                           "No release asset named #{@filename} found for " \
                                           "#{@owner}/#{@repo}@#{@tag}")
    end

    asset_url = "#{GitHub::API_URL}/repos/#{@owner}/#{@repo}/releases/assets/#{asset.fetch("id")}"
    ohai "Downloading #{@filename} from #{asset_url}"

    curl_download(
      asset_url,
      "--header", "Authorization: Bearer #{token}",
      "--header", "Accept: application/octet-stream",
      to:      temporary_path,
      timeout: timeout,
      secrets: [token],
    )
  end
end
