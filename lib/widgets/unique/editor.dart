import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'package:crop_image/crop_image.dart';

import '/platform.dart';
import '/layout.dart';
import '/image.dart';
import '/history.dart';
import '/io.dart';
import '/juggler.dart';
import '/preferences.dart';
import '/widgets/button.dart';
import '/widgets/dialog.dart';
import '/widgets/spinner.dart';
import '/widgets/snack_bar.dart';
import '/widgets/controls_list.dart';
import '/widgets/title_bar.dart';
import '/widgets/unique/save_button.dart';
import '/widgets/unique/carousel.dart';
import '/widgets/unique/histogram.dart';
import '/widgets/unique/navigation.dart';
import '/widgets/unique/controls.dart';
import '/widgets/unique/geometry_controls.dart';
import '/widgets/unique/share_controls.dart';
import '/widgets/unique/toolbar.dart';
import '/widgets/unique/image.dart';

class SlyEditorPage extends StatefulWidget {
  final SlyJuggler juggler;

  const SlyEditorPage({super.key, required this.juggler});

  @override
  State<SlyEditorPage> createState() => _SlyEditorPageState();
}

class _SlyEditorPageState extends State<SlyEditorPage> {
  final _saveButtonKey = GlobalKey<SlySaveButtonState>();
  final _imageViewKey = GlobalKey();
  GlobalKey _controlsKey = GlobalKey();
  GlobalKey _carouselKey = GlobalKey();

  Widget? _controlsChild;

  late final SlyJuggler juggler = widget.juggler;

  CropController? get _cropController => juggler.cropController;
  SlyImage get _originalImage => juggler.originalImage;
  SlyImage get _editedImage => juggler.editedImage!;
  set _editedImage(value) => juggler.editedImage = value;

  bool newImage = false;

  Widget? _histogram;

  Uint8List? _originalImageData;
  Uint8List? _editedImageData;

  bool _saveMetadata = true;
  SlyImageFormat _saveFormat = SlyImageFormat.png;
  bool _saveOnLoad = false;
  bool _saveAll = false;

  bool _cropChanged = false;
  bool _portraitCrop = false;

  late final HistoryManager history = HistoryManager(
    () => _editedImage,
    () {
      updateImage();
      _controlsKey = GlobalKey();
    },
  );

  int _selectedPageIndex = 0;
  bool _showHistogram = false;
  late bool _showCarousel = juggler.images.length > 1;

  SlySaveButton? _saveButton;
  final String _saveButtonLabel = isIOS ? 'Save to Photos' : 'Save';

  void _startSave() async {
    _saveButton?.setChild(
      const Padding(
        padding: EdgeInsets.all(6),
        child: SizedBox(
          width: 24,
          height: 24,
          child: SlySpinner(),
        ),
      ),
    );

    SlyImageFormat? format;

    await showSlyDialog(
      context,
      'Choose a Quality',
      <Widget>[
        SlyButton(
          onPressed: () {
            format = SlyImageFormat.jpeg75;
            Navigator.pop(context);
          },
          child: const Text('For Sharing'),
        ),
        SlyButton(
          onPressed: () {
            format = SlyImageFormat.jpeg90;
            Navigator.pop(context);
          },
          child: const Text('For Storing'),
        ),
        SlyButton(
          onPressed: () {
            format = SlyImageFormat.png;
            Navigator.pop(context);
          },
          child: const Text('Lossless'),
        ),
        const SlyCancelButton(),
      ],
    );

    // The user cancelled the format selection
    if (format == null) {
      _saveButton?.setChild(Text(_saveButtonLabel));
      return;
    }

    _saveFormat = format!;

    if (_editedImage.loading) {
      _saveOnLoad = true;
    } else {
      _save();
    }
  }

  Future<void> _save() async {
    final List<Map<String, dynamic>?> images =
        _saveAll ? juggler.images : [juggler.selectedImage];
    _saveAll = false;

    final newImages = <Uint8List>[];
    final fileNames = <String?>[];

    for (final image in images) {
      if (image == null) continue;

      final copyImage =
          SlyImage.from(image['editedImage'] ?? image['originalImage']);

      if (!{copyImage.rotation.min, copyImage.rotation.max}
          .contains(copyImage.rotation.value)) {
        copyImage.rotate(copyImage.rotation.value * 90);
      }

      final hflip = copyImage.hflip.value;
      final vflip = copyImage.vflip.value;

      if (hflip && vflip) {
        copyImage.flip(SlyImageFlipDirection.both);
      } else if (hflip) {
        copyImage.flip(SlyImageFlipDirection.horizontal);
      } else if (vflip) {
        copyImage.flip(SlyImageFlipDirection.vertical);
      }

      if (_saveMetadata) {
        copyImage.copyMetadataFrom(image['originalImage']);
      } else {
        copyImage.removeMetadata();
      }

      newImages.add(await copyImage.encode(format: _saveFormat, fullRes: true));
      fileNames.add(image['suggestedFileName']);

      copyImage.dispose();
    }

    await saveImages(
      newImages,
      fileNames: fileNames,
      fileExtension: _saveFormat == SlyImageFormat.png ? 'png' : 'jpg',
    );

    if (mounted) {
      _saveButton?.setChild(
        const ImageIcon(
          AssetImage('assets/icons/checkmark.webp'),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 2500));
    }

    _saveButton?.setChild(Text(_saveButtonLabel));
  }

  void _removeImage() => showSlyDialog(context, 'Remove Image?', [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: const Text(
              'The original will not be deleted, but unsaved edits will be lost.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        SlyButton(
          onPressed: () {
            juggler.remove(juggler.selected);
            Navigator.pop(context);
          },
          child: const Text('Remove'),
        ),
        const SlyCancelButton(),
      ]);

  void _onImageUpdate(event) {
    if (!mounted) return;

    switch (event) {
      case 'image added':
        setState(() => _carouselKey = GlobalKey());

      case 'new image':
        _originalImageData = null;
        _originalImage.encode(format: SlyImageFormat.png).then((data) {
          if (!mounted) return;
          setState(() => _originalImageData = data);
        });

        _editedImageData = null;
        _editedImage.encode(format: SlyImageFormat.jpeg75).then((data) {
          if (!mounted) return;
          setState(() => _editedImageData = data);
        });

        getHistogram(_editedImage).then((data) {
          if (!mounted) return;
          setState(() => _histogram = data);
        });

        setState(() {
          newImage = true;
          _controlsKey = GlobalKey();
        });

      case 'updated':
        if (_saveOnLoad) {
          _save();
          _saveOnLoad = false;
        }

        final hash = _editedImage.hashCode;

        _editedImage.encode(format: SlyImageFormat.jpeg75).then((data) {
          if (!mounted || _editedImage.hashCode != hash) return;

          setState(() => _editedImageData = data);
        });

        getHistogram(_editedImage).then((data) {
          if (!mounted) return;
          setState(() => _histogram = data);
        });

      case 'removed':
        setState(
            () => _showCarousel = (_showCarousel && juggler.images.length > 1));
        setState(() => _carouselKey = GlobalKey());
    }
  }

  @override
  void initState() {
    prefs.then((value) {
      final showHistogram = value.getBool('showHistogram');
      if (showHistogram == null) return;

      setState(() => _showHistogram = showHistogram);
    });

    juggler.controller.stream.listen(_onImageUpdate);
    updateImage();

    _originalImage.encode(format: SlyImageFormat.png).then((data) {
      if (!mounted) return;

      setState(() => _originalImageData = data);
    });

    super.initState();
  }

  @override
  void dispose() {
    _originalImage.dispose();
    _editedImage.dispose();

    _originalImageData = null;
    _editedImageData = null;

    super.dispose();
  }

  void updateImage() async => _editedImage.applyEditsProgressive();

  Future<void> updateCroppedImage() async {
    if (_cropController?.crop == null) return;

    final croppedImage = SlyImage.from(_originalImage);
    await croppedImage.crop(_cropController!.crop);

    croppedImage.lightAttributes = _editedImage.lightAttributes;
    croppedImage.colorAttributes = _editedImage.colorAttributes;
    croppedImage.effectAttributes = _editedImage.effectAttributes;
    croppedImage.geometryAttributes = _editedImage.geometryAttributes;

    _editedImage.dispose();
    _editedImage = croppedImage;

    updateImage();
  }

  void flipImage(SlyImageFlipDirection direction) {
    if (!mounted) return;

    setState(() {
      switch (direction) {
        case SlyImageFlipDirection.horizontal:
          _editedImage.hflip.value = !_editedImage.hflip.value;
        case SlyImageFlipDirection.vertical:
          _editedImage.vflip.value = !_editedImage.vflip.value;
        case SlyImageFlipDirection.both:
          _editedImage.hflip.value = !_editedImage.hflip.value;
          _editedImage.vflip.value = !_editedImage.vflip.value;
      }
    });
  }

  void toggleCarousel() => juggler.images.length <= 1
      ? juggler.editImages(
          context: context,
          loadingCallback: () => showSlySnackBar(
            context,
            'Loading',
            loading: true,
          ),
        )
      : setState(() => _showCarousel = !_showCarousel);

  void showOriginal() async {
    if (_editedImageData == _originalImageData) return;

    Uint8List? previous;

    if (_editedImageData != null) {
      previous = Uint8List.fromList(_editedImageData!);
    } else {
      previous = null;
    }

    setState(() => _editedImageData = _originalImageData);

    await Future.delayed(
      const Duration(milliseconds: 1500),
    );

    if (_editedImageData != _originalImageData) {
      previous = null;
      return;
    }

    setState(() => _editedImageData = previous);

    previous = null;
  }

  Widget getControlsChild(int index) {
    switch (index) {
      case 1:
        return SlyControlsListView(
          key: const Key('colorControls'),
          attributes: _editedImage.colorAttributes,
          history: history,
          updateImage: updateImage,
        );
      case 2:
        return SlyControlsListView(
          key: const Key('effectControls'),
          attributes: _editedImage.effectAttributes,
          history: history,
          updateImage: updateImage,
        );
      case 3:
        return SlyGeometryControls(
          cropController: _cropController,
          setCropChanged: (value) => _cropChanged = value,
          getPortraitCrop: () => _portraitCrop,
          setPortraitCrop: (value) => setState(() => _portraitCrop = value),
          rotation: _editedImage.rotation,
          rotate: (value) => setState(
            () => _editedImage.rotation.value = value,
          ),
          flipImage: flipImage,
        );
      case 4:
        return SlyControlsListView(
          key: const Key('colorControls'),
          attributes: _editedImage.colorAttributes,
          history: history,
          updateImage: updateImage,
        );
      case 5:
        return SlyShareControls(
          getSaveMetadata: () => _saveMetadata,
          setSaveMetadata: (value) => _saveMetadata = value,
          multipleImages: juggler.images.length > 1,
          saveButton: _saveButton,
          saveAll: () {
            _saveAll = true;
            _startSave();
          },
          copyEdits: () {
            juggler.copyEdits();
            // This is so that whether the Copy/Paste buttons are visible updates
            setState(() => _controlsChild = getControlsChild(index));
            showSlySnackBar(context, 'Copied');
          },
          pasteEdits: juggler.pasteEdits,
          canPasteEdits: juggler.copiedEdits != null &&
              juggler.copiedEdits != juggler.editedImage,
        );
      default:
        return SlyControlsListView(
          key: const Key('lightControls'),
          attributes: _editedImage.lightAttributes,
          history: history,
          updateImage: updateImage,
        );
    }
  }

  void navigationDestinationSelected(int index) {
    if (_selectedPageIndex == index) return;
    if (_selectedPageIndex == 3 && _cropChanged) {
      updateCroppedImage();
      _cropChanged = false;
    }

    _selectedPageIndex = index;

    setState(() => _controlsChild = getControlsChild(index));
  }

  @override
  Widget build(BuildContext context) {
    if (newImage) {
      if (_selectedPageIndex == 3) _selectedPageIndex = 0;
      _controlsChild = getControlsChild(_selectedPageIndex);
      newImage = false;
    }

    _controlsChild ??= getControlsChild(_selectedPageIndex);
    _saveButton ??= SlySaveButton(
      key: _saveButtonKey,
      label: _saveButtonLabel,
      onPressed: _startSave,
    );

    final imageView = SlyImageView(
      key: _imageViewKey,
      originalImageData: _originalImageData,
      editedImageData: _editedImageData,
      cropController: _cropController,
      onCrop: (rect) => _cropChanged = true,
      showCropView: () => _selectedPageIndex == 3,
      hflip: _editedImage.hflip,
      vflip: _editedImage.vflip,
      rotation: _editedImage.rotation,
    );

    final controlsView = SlyControlsView(
      key: _controlsKey,
      child: _controlsChild,
    );

    final toolbar = SlyToolbar(
      history: history,
      pageHasHistogram: () => {0, 1}.contains(_selectedPageIndex),
      getShowHistogram: () => _showHistogram,
      setShowHistogram: (value) => setState(
        () => _showHistogram = value,
      ),
      showOriginal: showOriginal,
    );

    final histogram = AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutQuint,
      child: {0, 1}.contains(_selectedPageIndex) && _showHistogram
          ? Padding(
              padding: EdgeInsets.only(
                bottom: isWide(context) ? 12 : 0,
                top: (isWide(context) && platformHasInsetTopBar) ? 0 : 8,
              ),
              child: SizedBox(
                height: isWide(context) ? 40 : 30,
                width: isWide(context) ? null : 150,
                child: _histogram,
              ),
            )
          : Container(),
    );

    final imageCarousel = SlyImageCarousel(
      visible: _showCarousel,
      juggler: juggler,
      removeImage: _removeImage,
      globalKey: _carouselKey,
    );

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.delete):
            DeleteToLineBreakIntent(forward: false),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          UndoTextIntent: CallbackAction<Intent>(
            onInvoke: (Intent intent) {
              history.undo();
              return null;
            },
          ),
          RedoTextIntent: CallbackAction<Intent>(
            onInvoke: (Intent intent) {
              history.redo();
              return null;
            },
          ),
          DeleteToLineBreakIntent: CallbackAction<Intent>(
            onInvoke: (Intent intent) {
              _removeImage();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            floatingActionButtonLocation: isTall(context)
                ? null
                : FloatingActionButtonLocation.startFloat,
            floatingActionButton: isWide(context)
                ? AnimatedPadding(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutQuint,
                    padding: !isTall(context) && _showCarousel
                        ? const EdgeInsets.only(
                            top: 3, bottom: 80, left: 3, right: 3)
                        : const EdgeInsets.all(3),
                    child: FloatingActionButton.small(
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(8),
                        ),
                      ),
                      backgroundColor: isTall(context)
                          ? Theme.of(context).focusColor
                          : Colors.black87,
                      foregroundColor: isTall(context)
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white,
                      focusColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.1),
                      hoverColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.1),
                      splashColor: Colors.transparent,
                      elevation: 0,
                      hoverElevation: 0,
                      focusElevation: 0,
                      disabledElevation: 0,
                      highlightElevation: 0,
                      onPressed: toggleCarousel,
                      child: AnimatedRotation(
                        turns: _showCarousel ? 1 / 8 : 0,
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeOutBack,
                        child: const ImageIcon(
                          AssetImage('assets/icons/add.webp'),
                          semanticLabel: 'More Images',
                        ),
                      ),
                    ),
                  )
                : null,
            body: isWide(context)
                ? Container(
                    color: Theme.of(context).brightness == Brightness.light
                        ? Colors.white
                        : Colors.black,
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            children: <Widget>[
                              SlyDragWindowBox(
                                child: SlyTitleBarBox(
                                  child: Container(),
                                ),
                              ),
                              Expanded(child: imageView),
                              imageCarousel,
                            ],
                          ),
                        ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth:
                                _selectedPageIndex == 3 ? double.infinity : 250,
                          ),
                          child: Column(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.only(
                                    bottomLeft: Radius.circular(12),
                                  ),
                                  child: Container(
                                    color: Theme.of(context).cardColor,
                                    child: AnimatedSize(
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                      curve: Curves.easeOutQuint,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          SlyDragWindowBox(
                                            child: SlyTitleBarBox(
                                              child: Container(),
                                            ),
                                          ),
                                          _selectedPageIndex == 3
                                              ? Container()
                                              : histogram,
                                          Expanded(child: controlsView),
                                          _selectedPageIndex != 3 &&
                                                  _selectedPageIndex != 5
                                              ? toolbar
                                              : Container(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          color: Theme.of(context).cardColor,
                          child: ClipRRect(
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(12),
                              bottomLeft: Radius.circular(12),
                            ),
                            child: SlyDragWindowBox(
                              child: Container(
                                color: Theme.of(context).hoverColor,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: <Widget>[
                                    const SlyTitleBar(),
                                    Expanded(
                                      child: SlyNavigationRail(
                                        getSelectedPageIndex: () =>
                                            _selectedPageIndex,
                                        onDestinationSelected: (index) =>
                                            navigationDestinationSelected(
                                                index),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: <Widget>[
                      const SlyTitleBar(),
                      Expanded(
                        child: _selectedPageIndex == 3
                            ? Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: <Widget>[
                                  Expanded(child: imageView),
                                  controlsView,
                                ],
                              )
                            : ListView(
                                children: _selectedPageIndex == 5
                                    ? <Widget>[
                                        imageView,
                                        controlsView,
                                      ]
                                    : <Widget>[
                                        imageView,
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [toolbar, histogram],
                                        ),
                                        controlsView,
                                      ],
                              ),
                      ),
                    ],
                  ),
            bottomNavigationBar: isWide(context)
                ? null
                : ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      topRight: Radius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                            padding: MediaQuery.of(context)
                                .padding
                                .copyWith(top: 0, bottom: 0),
                          ),
                          child: SlyNavigationBar(
                            getSelectedPageIndex: () => _selectedPageIndex,
                            getShowCarousel: () => _showCarousel,
                            toggleCarousel: toggleCarousel,
                            onDestinationSelected: (index) =>
                                navigationDestinationSelected(index),
                          ),
                        ),
                        imageCarousel,
                        Container(
                          height: MediaQuery.of(context).viewPadding.bottom,
                          color: Theme.of(context).hoverColor,
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
