/// How a folder lays out its apps.
enum FolderStyle: String, CaseIterable, Identifiable {
    /// 9 apps a page (3 × 3), like a folder on iPhone, up to 3 pages.
    case pages
    /// One page of up to 6 × 6 apps.
    case grid

    /// Folders saved before there was a choice get pages, unless they hold more than pages fit.
    init(savedName: String?, itemCount: Int) {
        if let saved = savedName.flatMap(FolderStyle.init(rawValue:)) {
            self = saved
        } else {
            self = itemCount <= FolderStyle.pages.capacity ? .pages : .grid
        }
    }

    var id: String { rawValue }

    /// The most apps a folder laid out this way holds.
    var capacity: Int {
        switch self {
        case .pages: return FolderLayout.appsPerPage * FolderLayout.maxPages
        case .grid: return FolderLayout.maxGridColumns * FolderLayout.maxGridRows
        }
    }

    var title: String {
        switch self {
        case .pages: return "Pages"
        case .grid: return "Grid"
        }
    }

    var summary: String {
        switch self {
        case .pages: return "3 pages of 9 apps"
        case .grid: return "36 apps on one page"
        }
    }
}
