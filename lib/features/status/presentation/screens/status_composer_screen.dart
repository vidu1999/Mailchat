import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/features/status/domain/status_service.dart';

class StatusComposerScreen extends StatefulWidget {
  const StatusComposerScreen({super.key});

  @override
  State<StatusComposerScreen> createState() => _StatusComposerScreenState();
}

class _StatusComposerScreenState extends State<StatusComposerScreen> {
  static const _colors = <Color>[
    Color(0xFF6366F1),
    Color(0xFF0F766E),
    Color(0xFFB45309),
    Color(0xFFBE123C),
    Color(0xFF334155),
    Color(0xFF7E22CE),
  ];
  final StatusService _service = StatusService();
  final TextEditingController _text = TextEditingController();
  final TextEditingController _caption = TextEditingController();
  XFile? _image;
  Uint8List? _imageBytes;
  int _color = _colors.first.toARGB32();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    _caption.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Photos',
            extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'heic'],
          ),
        ],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _image = file;
        _imageBytes = bytes;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not open that photo: $error');
    }
  }

  Future<void> _share() async {
    final userId = SupabaseClient.instance.userId;
    if (userId == null) {
      setState(() => _error = 'Sign in again to share an update.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_image != null) {
        await _service.createImage(
          userId: userId,
          image: _image!,
          caption: _caption.text,
        );
      } else {
        await _service.createText(
          userId: userId,
          text: _text.text,
          backgroundColor: _color,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted)
        setState(() {
          _busy = false;
          _error = error.toString();
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final background = Color(_color);
    return Scaffold(
      appBar: AppBar(
        title: Text(_image == null ? 'Text update' : 'Photo update'),
        actions: [
          IconButton(
            tooltip: 'Choose photo',
            onPressed: _busy ? null : _pickImage,
            icon: const Icon(Icons.photo_library_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            if (_image != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: AspectRatio(
                  aspectRatio: 0.82,
                  child: _imageBytes == null
                      ? const Center(child: CircularProgressIndicator())
                      : Image.memory(_imageBytes!, fit: BoxFit.cover),
                ),
              )
            else
              Container(
                height: 330,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(22),
                ),
                padding: const EdgeInsets.all(22),
                child: TextField(
                  controller: _text,
                  autofocus: true,
                  maxLength: 700,
                  maxLines: null,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'What’s new?',
                    hintStyle: TextStyle(color: Colors.white70),
                    border: InputBorder.none,
                  ),
                ),
              ),
            if (_image == null) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                children: [
                  for (final color in _colors)
                    InkWell(
                      onTap: () => setState(() => _color = color.toARGB32()),
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: color,
                        child: _color == color.toARGB32()
                            ? const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 18,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 14),
              TextField(
                controller: _caption,
                maxLength: 700,
                decoration: const InputDecoration(
                  labelText: 'Add a caption',
                  border: OutlineInputBorder(),
                ),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _pickImage,
                icon: const Icon(Icons.change_circle_outlined),
                label: const Text('Choose a different photo'),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy ? null : _share,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: Text(_busy ? 'Sharing…' : 'Share update'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Visible to people you have a direct MailChat conversation with. It expires after 24 hours.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
