import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

late List<CameraDescription> _cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Intentamos obtener las cámaras. Si falla (ej. emulador), evitamos el crash inicial.
  try {
    _cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Error al buscar cámaras: $e');
    _cameras = [];
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? controller;
  bool _isCameraInitialized = false;
  bool _isSaving = false;

  // Nueva lógica para pestañas y galería
  int _selectedIndex = 0;
  List<File> _photos = [];
  bool _isLoadingPhotos = false;

  // Cámara: índice y modo de flash
  int _cameraIndex = 0;
  FlashMode _flashMode = FlashMode.off;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  // Inicialización segura con solicitud de permisos
  Future<void> _initCamera() async {
    if (_selectedIndex != 0) return;

    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    if (statuses[Permission.camera] != PermissionStatus.granted) {
      _showError('Se necesita permiso de cámara');
      return;
    }

    if (_cameras.isEmpty) {
      _showError('No se detectaron cámaras (¿Estás en emulador?)');
      return;
    }

    controller = CameraController(
      _cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await controller!.initialize();
      if (!mounted) return;
      setState(() {
        _isCameraInitialized = true;
      });
    } catch (e) {
      _showError('Error iniciando cámara: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = controller;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (_selectedIndex == 0) _initCamera();
    }
  }

  // Cambia entre cámaras (si hay más de una)
  Future<void> _switchCamera() async {
    if (_cameras.length < 2) {
      _showError('No hay otra cámara disponible');
      return;
    }
    setState(() => _isCameraInitialized = false);
    try {
      await controller?.dispose();
      _cameraIndex = (_cameraIndex + 1) % _cameras.length;
      controller = CameraController(_cameras[_cameraIndex], ResolutionPreset.high, enableAudio: false);
      await controller!.initialize();
      try {
        await controller!.setFlashMode(_flashMode);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _isCameraInitialized = true);
    } catch (e) {
      _showError('Error al cambiar cámara: $e');
    }
  }

  // Cicla el modo de flash: off -> auto -> always -> torch -> off
  Future<void> _cycleFlashMode() async {
    final next = _flashMode == FlashMode.off
        ? FlashMode.auto
        : _flashMode == FlashMode.auto
            ? FlashMode.always
            : _flashMode == FlashMode.always
                ? FlashMode.torch
                : FlashMode.off;
    try {
      await controller?.setFlashMode(next);
      setState(() => _flashMode = next);
      final label = _flashMode == FlashMode.off
          ? 'Apagado'
          : _flashMode == FlashMode.auto
              ? 'Auto'
              : _flashMode == FlashMode.always
                  ? 'Siempre'
                  : 'Torch';
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Flash: $label')));
    } catch (e) {
      _showError('No se puede cambiar flash: $e');
    }
  }

  IconData _flashIcon() {
    switch (_flashMode) {
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.torch:
        return Icons.flashlight_on;
      default:
        return Icons.flash_off;
    }
  }

  String _flashLabel() {
    switch (_flashMode) {
      case FlashMode.auto:
        return 'Auto';
      case FlashMode.always:
        return 'Siempre';
      case FlashMode.torch:
        return 'Torch';
      default:
        return 'Apagado';
    }
  }

  Future<void> _takePicture() async {
    if (controller == null || !controller!.value.isInitialized || _isSaving) return;

    try {
      setState(() => _isSaving = true);

      final XFile image = await controller!.takePicture();

      Map<Permission, PermissionStatus> storageStatuses = await [
        Permission.storage,
        Permission.photos,
      ].request();

      if (!(storageStatuses[Permission.storage] == PermissionStatus.granted ||
          storageStatuses[Permission.photos] == PermissionStatus.granted)) {
        _showError('Se necesita permiso de almacenamiento para guardar la foto');
        return;
      }

      await Gal.putImage(image.path);

      // Guardamos también una copia en el directorio de la app para mostrarla en la galería interna
      await _saveToLocalDir(image);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('¡Guardado en Galería! 📸'),
          backgroundColor: Colors.green,
        ),
      );

      if (_selectedIndex == 1) await _loadPhotos();
    } catch (e) {
      _showError('Error al guardar: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<String> _saveToLocalDir(XFile image) async {
    final dir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${dir.path}/photos');
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }
    final fileName = 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final savedFile = await File(image.path).copy('${photosDir.path}/$fileName');
    return savedFile.path;
  }

  Future<void> _loadPhotos() async {
    setState(() => _isLoadingPhotos = true);
    final dir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${dir.path}/photos');
    if (!await photosDir.exists()) {
      setState(() {
        _photos = [];
        _isLoadingPhotos = false;
      });
      return;
    }

    final files = photosDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jpg') || f.path.toLowerCase().endsWith('.jpeg') || f.path.toLowerCase().endsWith('.png'))
        .toList();

    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    setState(() {
      _photos = files;
      _isLoadingPhotos = false;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  Widget _buildCameraView() {
    if (!_isCameraInitialized || controller == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text("Iniciando cámara..."),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Container(
                width: double.infinity,
                color: Colors.black,
                child: CameraPreview(controller!),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: IconButton(
                  icon: Icon(_flashIcon(), color: Colors.white),
                  onPressed: _cycleFlashMode,
                  tooltip: _flashLabel(),
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: IconButton(
                  icon: const Icon(Icons.cameraswitch, color: Colors.white),
                  onPressed: _switchCamera,
                  tooltip: 'Cambiar cámara',
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(20),
          color: Colors.black87,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _isSaving
                  ? const CircularProgressIndicator(color: Colors.white)
                  : FloatingActionButton(
                      onPressed: _takePicture,
                      backgroundColor: Colors.white,
                      child: const Icon(Icons.camera, color: Colors.black, size: 30),
                    ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGalleryView() {
    if (_isLoadingPhotos) return const Center(child: CircularProgressIndicator());

    if (_photos.isEmpty) return const Center(child: Text('No hay fotos aún', style: TextStyle(fontSize: 16)));

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4),
      itemCount: _photos.length,
      itemBuilder: (context, index) {
        final file = _photos[index];
        return GestureDetector(
          onTap: () => _openPhotoFullScreen(file),
          child: Image.file(file, fit: BoxFit.cover),
        );
      },
    );
  }

  void _openPhotoFullScreen(File file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Foto')),
          body: Center(child: Image.file(file)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildCameraView(),
          _buildGalleryView(),
          const MusicPlayer(),
        ],
      ),
      appBar: AppBar(title: Text(_selectedIndex == 0 ? 'Cámara Segura' : _selectedIndex == 1 ? 'Galería' : 'Música')),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) async {
          if (index == _selectedIndex) return;
          setState(() {
            _selectedIndex = index;
            if (index == 0) {
              _isCameraInitialized = false;
            } else {
              controller?.dispose();
              controller = null;
              _isCameraInitialized = false;
            }
          });
          if (index == 0) {
            await _initCamera();
          } else if (index == 1) {
            await _loadPhotos();
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.camera_alt), label: 'Cámara'),
          BottomNavigationBarItem(icon: Icon(Icons.photo_library), label: 'Galería'),
          BottomNavigationBarItem(icon: Icon(Icons.music_note), label: 'Música'),
        ],
      ),
    );
  }
}


class MusicPlayer extends StatefulWidget {
  const MusicPlayer({Key? key}) : super(key: key);

  @override
  State<MusicPlayer> createState() => _MusicPlayerState();
}

class _MusicPlayerState extends State<MusicPlayer> {
  final AudioPlayer _player = AudioPlayer();
  final List<String> _tracks = [];
  bool _shuffle = false;

  @override
  void initState() {
    super.initState();
    _player.playerStateStream.listen((_) => setState(() {}));
    _player.currentIndexStream.listen((_) => setState(() {}));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['mp3'],
    );

    if (result == null) return;

    final files = result.files.where((f) => f.path != null).toList();
    if (files.isEmpty) return;

    final newSources = files.map((f) => AudioSource.uri(Uri.file(f.path!), tag: f.name)).toList();

    try {
      final audioSource = _player.audioSource;
      if (audioSource == null) {
        await _player.setAudioSource(ConcatenatingAudioSource(children: newSources));
      } else if (audioSource is ConcatenatingAudioSource) {
        await audioSource.addAll(newSources);
      }

      setState(() {
        _tracks.addAll(files.map((f) => f.path!));
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al añadir archivos: $e')));
    }
  }

  String _trackName(int index) {
    try {
      final path = _tracks[index];
      return p.basename(path);
    } catch (_) {
      return 'Pista ${index + 1}';
    }
  }

  String _formatTime(Duration d) => d.toString().split('.').first.substring(2);

  Future<void> _toggleShuffle() async {
    _shuffle = !_shuffle;
    await _player.setShuffleModeEnabled(_shuffle);
    if (_shuffle) await _player.shuffle();
    setState(() {});
  }

  Future<void> _playIndex(int index) async {
    if (_player.sequenceState == null) return;
    await _player.seek(Duration.zero, index: index);
    await _player.play();
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = _player.currentIndex ?? -1;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.add),
                  label: const Text('Agregar MP3'),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: Icon(Icons.shuffle, color: _shuffle ? Colors.greenAccent : Colors.white),
                  onPressed: _toggleShuffle,
                  tooltip: 'Aleatorio',
                ),
              ],
            ),
          ),

          Expanded(
            child: _tracks.isEmpty
                ? const Center(child: Text('No hay pistas. Agrega MP3s.'))
                : ListView.builder(
                    itemCount: _tracks.length,
                    itemBuilder: (context, index) {
                      final selected = index == currentIndex;
                      return ListTile(
                        leading: Icon(selected ? Icons.play_arrow : Icons.music_note),
                        title: Text(_trackName(index)),
                        selected: selected,
                        onTap: () => _playIndex(index),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () async {
                            final audioSource = _player.audioSource;
                            if (audioSource is ConcatenatingAudioSource) {
                              await audioSource.removeAt(index);
                            }
                            setState(() => _tracks.removeAt(index));
                          },
                        ),
                      );
                    },
                  ),
          ),

          // Controles
          StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (context, snapPos) {
              final position = snapPos.data ?? Duration.zero;
              final duration = _player.duration ?? Duration.zero;
              final max = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
              final value = position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble();

              return Column(
                children: [
                  Slider(
                    min: 0,
                    max: max,
                    value: value,
                    onChanged: (v) {
                      final seekTo = Duration(milliseconds: v.toInt());
                      _player.seek(seekTo);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatTime(position)),
                        Text(_formatTime(duration)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.replay_10),
                  onPressed: () async {
                    final pos = _player.position;
                    await _player.seek(pos - const Duration(seconds: 10));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () async { if (_player.hasPrevious) await _player.seekToPrevious(); },
                ),
                IconButton(
                  icon: Icon(_player.playing ? Icons.pause_circle : Icons.play_circle, size: 48),
                  onPressed: () async {
                    if (_player.playing) {
                      await _player.pause();
                    } else {
                      await _player.play();
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: () async { if (_player.hasNext) await _player.seekToNext(); },
                ),
                IconButton(
                  icon: const Icon(Icons.forward_10),
                  onPressed: () async {
                    final pos = _player.position;
                    await _player.seek(pos + const Duration(seconds: 10));
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
