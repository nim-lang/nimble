# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest
import nimblepkg/download

suite "download":
  test "extractPackageName extracts package name from various URL formats":
    # GitHub URLs
    check extractPackageName("https://github.com/nim-lang/nimble.git") == "nimble"
    check extractPackageName("https://github.com/nim-lang/nimble") == "nimble"
    check extractPackageName("https://github.com/user/repo.git") == "repo"
    check extractPackageName("https://github.com/organization/package-name") ==
      "package-name"

    # GitLab URLs
    check extractPackageName("https://gitlab.com/user/mypackage") == "mypackage"
    check extractPackageName("https://gitlab.com/group/subgroup/project.git") ==
      "project"

    # Bitbucket URLs
    check extractPackageName("https://bitbucket.org/user/repository.git") == "repository"
    check extractPackageName("https://bitbucket.org/team/project") == "project"

    # Generic git URLs
    check extractPackageName("git://example.com/foo/bar.git") == "bar"
    check extractPackageName("git://server.org/path/to/repo.git") == "repo"
    check extractPackageName("ssh://git@example.com/user/package.git") == "package"

    # HTTP/HTTPS URLs
    check extractPackageName("http://example.com/repos/mypackage.git") == "mypackage"
    check extractPackageName("https://custom-git.com/projects/awesome-lib") ==
      "awesome-lib"

    # Edge cases
    check extractPackageName("https://github.com/user/repo.tar.gz") == "repo"
    check extractPackageName("https://example.com/package.bundle") == "package"
    check extractPackageName("https://server.com/path/to/deeply/nested/package") ==
      "package"

    # URLs with special characters
    check extractPackageName("https://github.com/user/my_package-2.git") ==
      "my_package-2"
    check extractPackageName("https://gitlab.com/user/package.v2") == "package"

  test "extractPackageName handles edge cases gracefully":
    # URL without path (returns the domain part)
    check extractPackageName("https://example.com") == "example"

    # Just a package name (no slashes)
    check extractPackageName("package") == "package"
    check extractPackageName("package.git") == "package"

  test "removeTrailingGitString removes .git suffix":
    check removeTrailingGitString("https://github.com/nim-lang/nimble.git") ==
      "https://github.com/nim-lang/nimble"
    check removeTrailingGitString("https://github.com/nim-lang/nimble") ==
      "https://github.com/nim-lang/nimble"
    check removeTrailingGitString("repo.git") == "repo"
    check removeTrailingGitString("git") == "git"
      # Should not remove if string is too short
    check removeTrailingGitString(".git") == ".git"
      # Should not remove if string is exactly .git
