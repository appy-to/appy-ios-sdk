sdk_version = File.read(File.join(__dir__, 'Sources', 'AppySDK', 'Appy.swift'))[/sdkVersion = "([^"]+)"/, 1]

Pod::Spec.new do |s|
  s.name = 'AppySDK'
  s.version = sdk_version
  s.summary = 'Deep links, deferred deep links, install attribution and events for apps that use Appy smart links.'
  s.homepage = 'https://appy.to/docs/sdk/ios'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = { 'Appy' => 'support@appy.to' }
  s.source = { :git => 'https://github.com/appy-to/appy-ios-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target = '13.0'
  s.swift_versions = ['5.9']
  s.source_files = 'Sources/AppySDK/**/*.swift'
  s.resource_bundles = { 'AppySDK_Privacy' => ['Sources/AppySDK/Resources/PrivacyInfo.xcprivacy'] }
  s.frameworks = 'Foundation', 'UIKit'
end
