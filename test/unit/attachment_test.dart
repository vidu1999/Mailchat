import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/shared/services/attachment_service.dart';

/// File names and MIME types come from the platform picker, which means they
/// come from the user. These are the two functions that touch that input, so
/// they are the ones worth pinning.
void main() {
  group('AttachmentService.mimeTypeFor', () {
    test('maps the image types people actually send', () {
      expect(AttachmentService.mimeTypeFor('holiday.JPG'), 'image/jpeg');
      expect(AttachmentService.mimeTypeFor('a.jpeg'), 'image/jpeg');
      expect(AttachmentService.mimeTypeFor('b.png'), 'image/png');
      expect(AttachmentService.mimeTypeFor('c.heic'), 'image/heic');
    });

    test('maps documents and archives', () {
      expect(AttachmentService.mimeTypeFor('spec.pdf'), 'application/pdf');
      expect(AttachmentService.mimeTypeFor('notes.txt'), 'text/plain');
      expect(AttachmentService.mimeTypeFor('sheet.xlsx'),
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      expect(AttachmentService.mimeTypeFor('bundle.zip'), 'application/zip');
    });

    test('is case-insensitive', () {
      expect(AttachmentService.mimeTypeFor('REPORT.PDF'), 'application/pdf');
    });

    test('falls back to octet-stream rather than guessing', () {
      // An unknown type is genuinely unknown; claiming text/plain would make the
      // viewer try to render binary data.
      expect(AttachmentService.mimeTypeFor('thing.unknownext'),
          'application/octet-stream');
      expect(AttachmentService.mimeTypeFor('noextension'),
          'application/octet-stream');
      expect(AttachmentService.mimeTypeFor('trailingdot.'),
          'application/octet-stream');
    });

    test('uses the last dot, not the first', () {
      expect(AttachmentService.mimeTypeFor('archive.tar.gz'),
          'application/octet-stream');
      expect(AttachmentService.mimeTypeFor('v1.2.report.pdf'), 'application/pdf');
    });
  });

  group('AttachmentService.sanitiseFileName', () {
    test('strips paths so an upload cannot escape its folder', () {
      expect(AttachmentService.sanitiseFileName('../../etc/passwd'), 'passwd');
      expect(AttachmentService.sanitiseFileName('folder/photo.png'), 'photo.png');
    });

    test('replaces characters that would need URL encoding', () {
      expect(AttachmentService.sanitiseFileName('my report (final).pdf'),
          'my_report__final_.pdf');
    });

    test('never returns an empty name', () {
      expect(AttachmentService.sanitiseFileName(''), 'attachment');
      expect(AttachmentService.sanitiseFileName('...'), 'attachment');
      // Whitespace becomes underscores, which is a legitimate file name; the
      // point is that it is never empty.
      expect(AttachmentService.sanitiseFileName('   '), '___');
    });

    test('keeps the tail of a long name so the extension survives', () {
      final long = 'x' * 200 + '.pdf';
      final cleaned = AttachmentService.sanitiseFileName(long);
      expect(cleaned.length, lessThanOrEqualTo(80));
      expect(cleaned.endsWith('.pdf'), isTrue);
    });
  });

  group('AttachmentService.formatSize', () {
    test('reads the way people expect', () {
      expect(AttachmentService.formatSize(512), '512 B');
      expect(AttachmentService.formatSize(2048), '2 KB');
      expect(AttachmentService.formatSize(2 * 1024 * 1024), '2.0 MB');
    });
  });

  group('size limit', () {
    test('is 10 MB, which the picker copy states', () {
      expect(AttachmentService.maxBytes, 10 * 1024 * 1024);
    });
  });
}
