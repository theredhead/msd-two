import Foundation

/// Localized text for IconPicker; resource lookup and formatting stay out of the UI code.
final class IconPickerIntl {
  private let bundle: Bundle

  init(bundle: Bundle = .main) {
    self.bundle = bundle
  }

  func initialQuery(searchName: String) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "initialQuery", tableName: "IconPicker", bundle: bundle, value: "%1$@",
        comment: "IconPicker: Formatted message. searchName: runtime text; keep its placeholder"),
      searchName)
  }

  var chooseAnImageFirst: String {
    NSLocalizedString(
      "chooseAnImageFirst", tableName: "IconPicker", bundle: bundle,
      value: "Choose an image first.",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var chooseLocalImage: String {
    NSLocalizedString(
      "chooseLocalImage", tableName: "IconPicker", bundle: bundle, value: "Choose Local Image…",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var chooseDeviceImage: String {
    NSLocalizedString(
      "chooseDeviceImage", tableName: "IconPicker", bundle: bundle, value: "Choose Device Image",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var clickAnImageResultOrChoose: String {
    NSLocalizedString(
      "clickAnImageResultOrChoose", tableName: "IconPicker", bundle: bundle,
      value: "Click an image result, or choose a local image.",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var couldNotLoadThatImageTry: String {
    NSLocalizedString(
      "couldNotLoadThatImageTry", tableName: "IconPicker", bundle: bundle,
      value: "Could not load that image. Try another result or a local file.",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var dragAndZoomThenUseThis: String {
    NSLocalizedString(
      "dragAndZoomThenUseThis", tableName: "IconPicker", bundle: bundle,
      value: "Drag and zoom, then use this crop.",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var dragToPositionTheSquareCrop: String {
    NSLocalizedString(
      "dragToPositionTheSquareCrop", tableName: "IconPicker", bundle: bundle,
      value: "Drag to position the square crop.",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var ifNoImagesAppearTryAnother: String {
    NSLocalizedString(
      "ifNoImagesAppearTryAnother", tableName: "IconPicker", bundle: bundle,
      value: "If no images appear, try another search or choose a local image.",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var loadingSelectedImage: String {
    NSLocalizedString(
      "loadingSelectedImage", tableName: "IconPicker", bundle: bundle,
      value: "Loading selected image…",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var search: String {
    NSLocalizedString(
      "search", tableName: "IconPicker", bundle: bundle, value: "Search",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var searchUnavailableTryAgainOrChoose: String {
    NSLocalizedString(
      "searchUnavailableTryAgainOrChoose", tableName: "IconPicker", bundle: bundle,
      value: "Search unavailable. Try again or choose a local image.",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var searchingDuckduckgoImages: String {
    NSLocalizedString(
      "searchingDuckduckgoImages", tableName: "IconPicker", bundle: bundle,
      value: "Searching DuckDuckGo images…",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var selectAnImageToCrop: String {
    NSLocalizedString(
      "selectAnImageToCrop", tableName: "IconPicker", bundle: bundle,
      value: "Select an image to crop",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var useThisCrop: String {
    NSLocalizedString(
      "useThisCrop", tableName: "IconPicker", bundle: bundle, value: "Use This Crop",
      comment: "IconPicker: User-visible label, instruction, or error message.")
  }

  var searchingForImages: String {
    NSLocalizedString(
      "searchingForImages", tableName: "IconPicker", bundle: bundle, value: "Searching for images…",
      comment: "Empty image-search grid while results load.")
  }

  func selectImage(number: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "selectImage", tableName: "IconPicker", bundle: bundle, value: "Select image %1$ld",
        comment: "Accessibility label for an image-search result, numbered from one."), number)
  }
}
