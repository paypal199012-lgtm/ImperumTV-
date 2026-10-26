platform :ios, '16.0'

target 'IPTVPlayer' do
  use_frameworks!
  # VLC spielt Formate ab, die der iPhone-Player nicht kann (z. B. MKV, AVI)
  pod 'MobileVLCKit', '~> 3.6'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end
  end
end
