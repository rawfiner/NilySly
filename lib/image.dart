import 'dart:typed_data';
import 'dart:async';
import 'dart:ui';
// import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:image/image.dart' as img;

import '/io.dart';

enum SlyImageFlipDirection { horizontal, vertical, both }

enum SlyImageFormat { png, jpeg75, jpeg90, jpeg100, tiff }

class SlyImageAttribute<T> {
  final String name;
  T value;

  SlyImageAttribute(this.name, this.value);

  SlyImageAttribute.copy(SlyImageAttribute attribute)
      : this(attribute.name, attribute.value);
}

class SlyClampedAttribute<T> extends SlyImageAttribute<T> {
  final T min;
  final T max;

  SlyClampedAttribute(
    super.name,
    super.value,
    this.min,
    this.max,
  );

  SlyClampedAttribute.copy(SlyClampedAttribute attribute)
      : this(
          attribute.name,
          attribute.value,
          attribute.min,
          attribute.max,
        );
}

class SlyOverflowAttribute extends SlyClampedAttribute<int> {
  @override
  set value(int v) {
    if (v < value) {
      if (v < min) v = max + v;
    } else if (v > value) {
      if (v > max) v = v - max;
    } else {
      return;
    }

    if (v == max) v = min;

    super.value = v;
  }

  SlyOverflowAttribute(
    super.name,
    super.value,
    super.min,
    super.max,
  );

  SlyOverflowAttribute.copy(SlyOverflowAttribute attribute)
      : this(
          attribute.name,
          attribute.value,
          attribute.min,
          attribute.max,
        );
}

class SlyRangeAttribute extends SlyClampedAttribute<double> {
  final double anchor;

  SlyRangeAttribute(
    super.name,
    super.value,
    this.anchor,
    super.min,
    super.max,
  );

  SlyRangeAttribute.copy(SlyRangeAttribute attribute)
      : this(
          attribute.name,
          attribute.value,
          attribute.anchor,
          attribute.min,
          attribute.max,
        );
}

class SlyBoolAttribute extends SlyImageAttribute<bool> {
  SlyBoolAttribute(super.name, super.value);

  SlyBoolAttribute.copy(SlyBoolAttribute attribute)
      : this(attribute.name, attribute.value);
}

class SlyImage {
  StreamController<String> controller = StreamController<String>();
  // bool shallow = false;

  img.Image _originalImage;
  img.Image _image;
  num _editsApplied = 0;
  int _loading = 0;

  Map<String, SlyRangeAttribute> lightAttributes = {
    'exposure': SlyRangeAttribute('Exposure', 0, 0, 0, 1),
    'brightness': SlyRangeAttribute('Brightness', 1, 1, 0.2, 1.8),
    'contrast': SlyRangeAttribute('Contrast', 1, 1, 0.4, 1.6),
    'blacks': SlyRangeAttribute('Blacks', 0, 0, 0, 127.5),
    'whites': SlyRangeAttribute('Whites', 255, 255, 76.5, 255),
    'mids': SlyRangeAttribute('Midtones', 127.5, 127.5, 25.5, 229.5),
  };

  Map<String, SlyRangeAttribute> colorAttributes = {
    'saturation': SlyRangeAttribute('Saturation', 1, 1, 0, 2),
    'temperature': SlyRangeAttribute('Temperature', 0, 0, -1, 1),
    'tint': SlyRangeAttribute('Tint', 0, 0, -1, 1),
  };

  Map<String, SlyRangeAttribute> effectAttributes = {
    'denoise': SlyRangeAttribute('Noise Reduction', 0, 0, 0, 1),
    'sharpness': SlyRangeAttribute('Sharpness', 0, 0, 0, 1),
    'sepia': SlyRangeAttribute('Sepia', 0, 0, 0, 1),
    'vignette': SlyRangeAttribute('Vignette', 0, 0, 0, 1),
    'border': SlyRangeAttribute('Border', 0, 0, -1, 1),
  };

  /// For informational purposes only, not actually reflected in the buffer
  Map<String, SlyImageAttribute> geometryAttributes = {
    'hflip': SlyBoolAttribute('Flip Horizontally', false),
    'vflip': SlyBoolAttribute('Flip Vertically', false),
    'rotation': SlyOverflowAttribute('Rotation', 0, 0, 4),
  };

  Map<String, SlyRangeAttribute> projAttributes = {
    'focal': SlyRangeAttribute('Focal length (equiv. 35mm)', 13, 13, 10, 30),
  };

  SlyRangeAttribute get exposure => lightAttributes['exposure']!;
  SlyRangeAttribute get brightness => lightAttributes['brightness']!;
  SlyRangeAttribute get contrast => lightAttributes['contrast']!;
  SlyRangeAttribute get blacks => lightAttributes['blacks']!;
  SlyRangeAttribute get whites => lightAttributes['whites']!;
  SlyRangeAttribute get mids => lightAttributes['mids']!;

  SlyRangeAttribute get saturation => colorAttributes['saturation']!;
  SlyRangeAttribute get temperature => colorAttributes['temperature']!;
  SlyRangeAttribute get tint => colorAttributes['tint']!;

  SlyRangeAttribute get denoise => effectAttributes['denoise']!;
  SlyRangeAttribute get sharpness => effectAttributes['sharpness']!;
  SlyRangeAttribute get sepia => effectAttributes['sepia']!;
  SlyRangeAttribute get vignette => effectAttributes['vignette']!;
  SlyRangeAttribute get border => effectAttributes['border']!;

  SlyBoolAttribute get hflip =>
      geometryAttributes['hflip']! as SlyBoolAttribute;
  SlyBoolAttribute get vflip =>
      geometryAttributes['vflip']! as SlyBoolAttribute;
  SlyOverflowAttribute get rotation =>
      geometryAttributes['rotation']! as SlyOverflowAttribute;

  SlyRangeAttribute get focal => projAttributes['focal']!;

  int get width => _image.width;
  int get height => _image.height;
  bool get loading => _loading > 0;

  /// True if the image is small enough and the device is powerful enough to load it.
  bool get canLoadFullRes {
    return (!kIsWeb && _originalImage.height <= 2000) ||
        _originalImage.height <= 500;
  }

  /// Creates a new `SlyImage` from another `src`.
  ///
  /// Note that if `src` is in the process of loading,
  /// the copied image might stay at a lower resolution until
  /// `applyEdits` or `applyEditsProgressive` is called on `this`.
  SlyImage.from(SlyImage src)
      : _image = img.Image.from(src._image),
        _originalImage = img.Image.from(src._originalImage) {
    copyEditsFrom(src);
  }

  /// Creates a new `SlyImage` from `image`.
  ///
  /// The `image` object is reused, so calling `.from`
  /// before invoking this constructor might be necessary
  /// if you plan on reusing `image`.
  SlyImage._fromImage(img.Image image)
      : _image = img.Image.from(image),
        _originalImage = image;

  /// Creates a new `SlyImage` from `data`.
  static Future<SlyImage?> fromData(Uint8List data) async {
    final imgImage = await loadImgImage(data);
    if (imgImage == null) return null;

    return SlyImage._fromImage(imgImage);
  }

  /// Creates a new shallow `SlyImage` from `file`.
  ///
  /// Shallow `SlyImage`s are not loaded into memory until the
  /// first operation that requires the buffer is performed on them.
  ///
  /// This means that if the original file is moved or removed,
  /// the image will no longer be valid.
  // SlyImage.shallowFromFile(File file)
  //     : shallow = true,
  //       _image = img.Image.empty(),
  //       _originalImage = img.Image.empty();

  /// Applies changes to the image's attrubutes.
  Future<void> applyEdits() async {
    _loading += 1;
    final applied = DateTime.now().millisecondsSinceEpoch;
    _editsApplied = applied;

    final editedImage =
        (await _buildEditCommand(_originalImage).executeThread()).outputImage;

    _loading -= 1;

    if (editedImage == null || _editsApplied > applied || controller.isClosed) {
      return;
    }

    _image = editedImage;
    controller.add('updated');
  }

  /// Applies changes to the image's attrubutes, progressively.
  ///
  /// The edits will first be applied to a <=500px tall thumbnail for fast preview.
  ///
  /// Finally, when ready, the image will be returned at the original size
  /// if the device can render such a large image.
  ///
  /// You can check this with `this.canLoadFullRes`.
  Future<void> applyEditsProgressive() async {
    _loading += 1;
    final applied = DateTime.now().millisecondsSinceEpoch;
    _editsApplied = applied;

    final List<Future<img.Image>> images = [];

    if (_originalImage.height > 700 ||
        (kIsWeb && _originalImage.height > 500)) {
      images.add(_getResizedImage(_originalImage, null, 500));
    }

    if (canLoadFullRes) {
      images.add(Future.value(_originalImage));
    } else if (!kIsWeb) {
      images.add(_getResizedImage(_originalImage, null, 1500));
    }

    for (Future<img.Image> editableImage in images) {
      if (_editsApplied > applied) {
        _loading -= 1;
        return;
      }

      final editedImage =
          (await _buildEditCommand(await editableImage).executeThread())
              .outputImage;
      if (editedImage == null) {
        _loading -= 1;
        return;
      }

      if (_editsApplied > applied) {
        _loading -= 1;
        return;
      }

      if (controller.isClosed) {
        _loading -= 1;
        return;
      }

      _image = editedImage;
      controller.add('updated');
    }

    _loading -= 1;
  }

  /// Copies Exif metadata from `src` to the image.
  void copyMetadataFrom(SlyImage src) {
    _image.exif = img.ExifData.from(src._image.exif);
    _originalImage.exif = img.ExifData.from(src._originalImage.exif);
  }

  /// Copies edits from `src` to the image.
  ///
  /// Doesn't copy geometry attributes if `skipGeometry` is true.
  ///
  /// Note that if you want to see the changes,
  /// you need to call `applyEdits` or `applyEditsProgressive` yourself.
  void copyEditsFrom(SlyImage src, {skipGeometry = false}) {
    for (int i = 0; i < 3; i++) {
      for (MapEntry<String, SlyRangeAttribute> entry in [
        src.lightAttributes,
        src.colorAttributes,
        src.effectAttributes,
      ][i]
          .entries) {
        [
          lightAttributes,
          colorAttributes,
          effectAttributes,
        ][i][entry.key] = SlyRangeAttribute.copy(entry.value);
      }
    }

    if (skipGeometry) return;

    geometryAttributes['hflip'] = SlyBoolAttribute.copy(src.hflip);
    geometryAttributes['vflip'] = SlyBoolAttribute.copy(src.vflip);
    geometryAttributes['rotation'] = SlyOverflowAttribute.copy(src.rotation);
  }

  /// Removes Exif metadata from the image.
  void removeMetadata() {
    _image.exif = img.ExifData();
    _originalImage.exif = img.ExifData();
  }

  /// Flips the image in `direction`.
  void flip(SlyImageFlipDirection direction) {
    final img.FlipDirection imgFlipDirection;

    switch (direction) {
      case SlyImageFlipDirection.horizontal:
        imgFlipDirection = img.FlipDirection.horizontal;
      case SlyImageFlipDirection.vertical:
        imgFlipDirection = img.FlipDirection.vertical;
      case SlyImageFlipDirection.both:
        imgFlipDirection = img.FlipDirection.both;
    }

    img.flip(_image, direction: imgFlipDirection);
    img.flip(_originalImage, direction: imgFlipDirection);
  }

  /// Rotates the image by `degree`
  void rotate(num degree) {
    if (degree == 360) return;

    _image = img.copyRotate(
      _image,
      angle: degree,
      interpolation: img.Interpolation.cubic,
    );
    _originalImage = img.copyRotate(
      _originalImage,
      angle: degree,
      interpolation: img.Interpolation.cubic,
    );
  }

  /// Crops the image to `rect`, normalized between 0 and 1.
  ///
  /// Note that the original image can never be recovered after this method call
  /// so it is recommended to make a copy of it if that is needed.
  ///
  /// Also note that if you want to see the changes,
  /// you need to call `applyEdits` or `applyEditsProgressive` yourself.
  Future<void> crop(Rect rect) async {
    final cmd = img.Command()
      ..image(_originalImage)
      ..copyCrop(
        x: (rect.left * width).round(),
        y: (rect.top * height).round(),
        width: (rect.width * width).round(),
        height: (rect.height * height).round(),
      );

    _originalImage = (await cmd.executeThread()).outputImage ?? _originalImage;
  }

  /// Returns the image encoded as `format`.
  ///
  /// Available formats are:
  /// - `png`
  /// - `jpeg100` - Quality 100
  /// - `jpeg90` - Quality 90
  /// - `jpeg75` - Quality 75
  /// - `tiff`
  ///
  /// If `fullRes` is not true, a lower resolution image might be returned
  /// if it looks like the device could not handle loading the entire image.
  ///
  /// You can check this with `this.canLoadFullRes`.
  ///
  /// `maxSideLength` defines the maximum length of the shorter side
  /// of the image in pixels. Unlimited (depending on `fullRes`) if omitted.
  Future<Uint8List> encode({
    SlyImageFormat? format = SlyImageFormat.png,
    bool fullRes = false,
    int? maxSideLength,
  }) async {
    if (fullRes && !canLoadFullRes) {
      await applyEdits();
    }

    final cmd = img.Command()..image(_image);

    if (maxSideLength != null &&
        (height > maxSideLength || width < maxSideLength)) {
      if (height > width) {
        cmd.copyResize(
          height: maxSideLength,
          interpolation: img.Interpolation.average,
        );
      } else {
        cmd.copyResize(
          width: maxSideLength,
          interpolation: img.Interpolation.average,
        );
      }
    }

    switch (format) {
      case SlyImageFormat.png:
        cmd.encodePng();
      case SlyImageFormat.jpeg75:
        cmd.encodeJpg(quality: 75);
      case SlyImageFormat.jpeg90:
        cmd.encodeJpg(quality: 90);
      case SlyImageFormat.jpeg100:
        cmd.encodeJpg(quality: 100);
      case SlyImageFormat.tiff:
        cmd.encodeTiff();
      default:
        cmd.encodePng();
    }

    return (await cmd.executeThread()).outputBytes!;
  }

  /// Returns a short list representing the RGB colors across the image,
  /// useful for building a histogram.
  Future<Uint8List> getHistogramData() async {
    final cmd = img.Command()
      ..image(_image)
      ..copyResize(width: 20, height: 20)
      ..convert(numChannels: 3);

    return (await cmd.executeThread()).outputImage!.buffer.asUint8List();
  }

  void dispose() {
    controller.close();
    _editsApplied = double.infinity;
  }

  img.Command _buildEditCommand(img.Image editableImage) {
    final cmd = img.Command()
      ..image(editableImage)
      ..copy();

    for (SlyRangeAttribute attribute in [temperature, tint]) {
      if (attribute.value != attribute.anchor) {
        cmd.colorOffset(
          red: 50 * temperature.value,
          green: 50 * tint.value * -1,
          blue: 50 * temperature.value * -1,
        );
        break;
      }
    }

    for (SlyRangeAttribute attribute in [
      exposure,
      brightness,
      contrast,
      saturation,
      blacks,
      whites,
      mids,
    ]) {
      if (attribute.value != attribute.anchor) {
        final b = blacks.value.round();
        final w = whites.value.round();
        final m = mids.value.round();

        cmd.adjustColor(
          exposure: exposure.value != exposure.anchor ? exposure.value : null,
          brightness:
              brightness.value != brightness.anchor ? brightness.value : null,
          contrast: contrast.value != contrast.anchor ? contrast.value : null,
          saturation:
              saturation.value != saturation.anchor ? saturation.value : null,
          blacks: img.ColorUint8.rgb(b, b, b),
          whites: img.ColorUint8.rgb(w, w, w),
          mids: img.ColorUint8.rgb(m, m, m),
        );
        break;
      }
    }

    if (sepia.value != sepia.anchor) {
      cmd.sepia(amount: sepia.value);
    }

    if (denoise.value != denoise.anchor) {
      cmd.convolution(
        filter: [
          1 / 16,
          2 / 16,
          1 / 16,
          2 / 16,
          4 / 16,
          2 / 16,
          1 / 16,
          2 / 16,
          1 / 16,
        ],
        amount: denoise.value,
      );
    }

    if (sharpness.value != sharpness.anchor) {
      cmd.convolution(
        filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
        amount: sharpness.value,
      );
    }

    if (vignette.value != vignette.anchor) {
      cmd.vignette(amount: vignette.value);
    }

    if (border.value != border.anchor) {
      cmd.copyExpandCanvas(
          backgroundColor: border.value > 0
              ? img.ColorRgb8(255, 255, 255)
              : img.ColorRgb8(0, 0, 0),
          padding: (border.value.abs() * (editableImage.width / 3)).round());
    }

    return cmd;
  }
}

Future<img.Image> _getResizedImage(
  img.Image image,
  int? width,
  int? height,
) async {
  final cmd = img.Command()
    ..image(image)
    ..copyResize(
      width: width,
      height: height,
      interpolation: img.Interpolation.average,
    );

  return (await cmd.executeThread()).outputImage!;
}
