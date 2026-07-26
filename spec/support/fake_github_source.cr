class FakeGitHubSource < ContributorMural::GitHubSource
  getter requested_repos = [] of String
  getter requested_orgs = [] of String
  getter requested_star_repos = [] of String
  getter requested_sponsor_logins = [] of String

  def initialize(@contributors : Array(ContributorMural::ResolvedUser) = [] of ContributorMural::ResolvedUser,
                 @members : Array(ContributorMural::ResolvedUser) = [] of ContributorMural::ResolvedUser,
                 @stargazers : Array(ContributorMural::ResolvedUser) = [] of ContributorMural::ResolvedUser,
                 @sponsors : Array(ContributorMural::ResolvedUser) = [] of ContributorMural::ResolvedUser)
  end

  def contributors(repo : String) : Array(ContributorMural::ResolvedUser)
    requested_repos << repo
    @contributors
  end

  def members(org : String) : Array(ContributorMural::ResolvedUser)
    requested_orgs << org
    @members
  end

  def stargazers(repo : String) : Array(ContributorMural::ResolvedUser)
    requested_star_repos << repo
    @stargazers
  end

  def sponsors(login : String) : Array(ContributorMural::ResolvedUser)
    requested_sponsor_logins << login
    @sponsors
  end
end
