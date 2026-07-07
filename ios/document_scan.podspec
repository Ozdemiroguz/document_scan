#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint document_scan.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'document_scan'
  s.version          = '0.1.0'
  s.summary          = 'Composable, native-light document scanner: corner detection + perspective correction, for realtime camera and static images.'
  s.description      = <<-DESC
Composable, native-light document scanner: corner detection + perspective correction, for realtime camera and static images. On iOS the detector uses Apple Vision — a system framework, so no bundled model and zero added binary.
                       DESC
  s.homepage         = 'https://github.com/Ozdemiroguz/document_scan'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Oğuzhan Özdemir' => 'oguzhan.ozdemir@nodelabs.software' }
  s.source           = { :path => '.' }
  s.source_files = 'document_scan/Sources/document_scan/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  # Apple Vision (rectangle detection) + Core Video (frame buffers) are system
  # frameworks — no bundled model, zero added binary.
  s.frameworks = 'Vision', 'CoreVideo', 'ImageIO'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Apple requires the plugin to bundle a privacy manifest. It declares no
  # tracking, no collected data, and no required-reason API usage — accurate for
  # a Vision-only detector that reads image files/frames and nothing else.
  s.resource_bundles = {'document_scan_privacy' => ['document_scan/Sources/document_scan/PrivacyInfo.xcprivacy']}
end
