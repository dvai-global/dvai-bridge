require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name             = 'DVAICapacitorFoundation'
  s.version          = package['version']
  s.summary          = package['description']
  s.license          = 'Custom (See LICENSE)'
  s.homepage         = package['repository']['url']
  s.author           = package['author']
  s.source           = { :git => package['repository']['url'], :tag => s.version.to_s }
  s.source_files     = 'ios/Sources/**/*.{swift,h,m,mm}'
  s.ios.deployment_target = '18.1'
  s.swift_version    = '5.9'
  s.dependency 'Capacitor'
  s.dependency 'Telegraph', '~> 0.40'
end
