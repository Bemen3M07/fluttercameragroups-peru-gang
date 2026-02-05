//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import audio_session
import gal
import just_audio

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  AudioSessionPlugin.register(with: registry.registrar(forPlugin: "AudioSessionPlugin"))
  GalPlugin.register(with: registry.registrar(forPlugin: "GalPlugin"))
  JustAudioPlugin.register(with: registry.registrar(forPlugin: "JustAudioPlugin"))
}
