# frozen_string_literal: true

require_relative "lib/kettle/paths/version"

Gem::Specification.new do |spec|
  spec.name = "kettle-paths"
  spec.version = Kettle::Paths::VERSION
  spec.authors = ["Peter H. Boling"]
  spec.email = ["floss@galtzo.com"]

  spec.summary = "Filesystem path comparison by identity, not by spelling."
  spec.description = <<~DESC.strip
    Path helpers that compare two filesystem paths by identity (inode / file
    index) rather than by string, so a directory spelled two valid ways still
    compares equal: symlinked ancestors (/home/x vs /var/home/x) and Windows
    8.3 short names (RUNNER~1 vs runneradmin). Pure Ruby, no dependencies, so it
    can be shared across MIT and AGPL tooling.
  DESC
  spec.homepage = "https://github.com/pboling/kettle-paths"
  spec.licenses = ["MIT"]
  spec.required_ruby_version = ">= 2.4.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{spec.version}"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/v#{spec.version}/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "https://www.rubydoc.info/gems/#{spec.name}/#{spec.version}"
  spec.metadata["funding_uri"] = "https://github.com/sponsors/pboling"
  spec.metadata["wiki_uri"] = "#{spec.homepage}/wiki"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .rspec spec/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
