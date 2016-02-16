# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'zewo/version'

Gem::Specification.new do |spec|
  spec.name          = "zewo-dev"
  spec.version       = Zewo::VERSION
  spec.authors       = ["David Ask"]
  spec.email         = ["david@formbound.com"]

  spec.summary       = %q{Summary}
  spec.description   = %q{Description}
  spec.homepage      = "http://github.com/Zewo"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "xcodeproj", "~> 0.28"
  spec.add_dependency "thor", "~> 0.19"
  spec.add_dependency "xcpretty", "~> 0.2"
  spec.add_dependency "colorize"
  
  

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
end
