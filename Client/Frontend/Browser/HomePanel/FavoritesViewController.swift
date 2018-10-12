/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Shared
import BraveShared
import XCGLogger
import Storage
import Deferred
import Data

private let log = Logger.browserLogger

protocol TopSitesDelegate: class {
    func didSelectUrl(url: URL)
    func didTapDuckDuckGoCallout()
}

class FavoritesViewController: UIViewController {
    private struct UI {
        static let statsHeight: CGFloat = 110.0
        static let statsBottomMargin: CGFloat = 5
        static let searchEngineCalloutPadding: CGFloat = 30.0
    }
    weak var linkNavigationDelegate: LinkNavigationDelegate?
    weak var delegate: TopSitesDelegate?
    
    // MARK: - Favorites collection view properties
    private lazy var collection: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 6
        
        let view = UICollectionView(frame: self.view.frame, collectionViewLayout: layout).then {
            $0.backgroundColor = PrivateBrowsingManager.shared.isPrivateBrowsing ? UX.HomePanel.BackgroundColorPBM : UX.HomePanel.BackgroundColor
            $0.delegate = self
        
            let cellIdentifier = FavoriteCell.identifier
            $0.register(FavoriteCell.self, forCellWithReuseIdentifier: cellIdentifier)
            $0.keyboardDismissMode = .onDrag
            $0.alwaysBounceVertical = true
            $0.accessibilityIdentifier = "Top Sites View"
            // Entire site panel, including the stats view insets
            $0.contentInset = UIEdgeInsets(top: UI.statsHeight, left: 0, bottom: 0, right: 0)
        }
        return view
    }()
    private lazy var dataSource: FavoritesDataSource = { return FavoritesDataSource() }()
    
    private let braveShieldStatsView = BraveShieldStatsView(frame: CGRect.zero).then {
        $0.autoresizingMask = [.flexibleWidth]
    }
    
    private let ddgLogo = UIImageView(image: #imageLiteral(resourceName: "duckduckgo"))
    
    private let ddgLabel = UILabel().then {
        $0.numberOfLines = 0
        $0.textColor = BraveUX.GreyD
        $0.font = UIFont.systemFont(ofSize: 14, weight: UIFont.Weight.regular)
        $0.text = Strings.DDG_promotion
    }
    
    private lazy var ddgButton = UIControl().then {
        $0.addTarget(self, action: #selector(showDDGCallout), for: .touchUpInside)
    }
    
    @objc private func showDDGCallout() {
        delegate?.didTapDuckDuckGoCallout()
    }
    
    // MARK: - Init/lifecycle
    
    private let profile: Profile
    
    init(profile: Profile) {
        self.profile = profile
        
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.do {
            $0.addObserver(self, selector: #selector(existingUserTopSitesConversion), 
                           name: Notification.Name.TopSitesConversion, object: nil)
            $0.addObserver(self, selector: #selector(privateBrowsingModeChanged), 
                           name: Notification.Name.PrivacyModeChanged, object: nil)
        }   
    }
    
    @objc func existingUserTopSitesConversion() {
        dataSource.refetch()
        collection.reloadData()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.do {
            $0.removeObserver(self, name: Notification.Name.TopSitesConversion, object: nil)
            $0.removeObserver(self, name: Notification.Name.PrivacyModeChanged, object: nil)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = PrivateBrowsingManager.shared.isPrivateBrowsing ? UX.HomePanel.BackgroundColorPBM : UX.HomePanel.BackgroundColor
        
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongGesture(gesture:)))
        collection.addGestureRecognizer(longPressGesture)
        
        view.addSubview(collection)
        collection.dataSource = dataSource
        dataSource.collectionView = collection
        
        // Could setup as section header but would need to use flow layout,
        // Auto-layout subview within collection doesn't work properly,
        // Quick-and-dirty layout here.
        var statsViewFrame: CGRect = braveShieldStatsView.frame
        statsViewFrame.origin.x = 20
        // Offset the stats view from the inset set above
        statsViewFrame.origin.y = -(UI.statsHeight + UI.statsBottomMargin)
        statsViewFrame.size.width = collection.frame.width - statsViewFrame.minX * 2
        statsViewFrame.size.height = UI.statsHeight
        braveShieldStatsView.frame = statsViewFrame
        
        collection.addSubview(braveShieldStatsView)
        collection.addSubview(ddgButton)
        
        ddgButton.addSubview(ddgLogo)
        ddgButton.addSubview(ddgLabel)
        
        makeConstraints()
        
        collectionContentSizeObservation = collection.observe(\.contentSize, options: [.new, .initial]) { [weak self] _, _ in
            self?.updateDuckDuckGoButtonLayout()
        }
        updateDuckDuckGoVisibility()
    }
    
    private var collectionContentSizeObservation: NSKeyValueObservation?
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // This makes collection view layout to recalculate its cell size.
        collection.collectionViewLayout.invalidateLayout()
    }
    
    private func updateDuckDuckGoButtonLayout() {
        let size = ddgButton.systemLayoutSizeFitting(UILayoutFittingExpandedSize)
        ddgButton.frame = CGRect(
            x: ceil((collection.bounds.width - size.width) / 2.0),
            y: collection.contentSize.height + UI.searchEngineCalloutPadding,
            width: size.width,
            height: size.height
        )
    }
    
    /// Handles long press gesture for UICollectionView cells reorder.
    @objc func handleLongGesture(gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let selectedIndexPath = collection.indexPathForItem(at: gesture.location(in: collection)) else {
                break
            }
            
            dataSource.isEditing = true
            collection.beginInteractiveMovementForItem(at: selectedIndexPath)
        case .changed:
            collection.updateInteractiveMovementTargetPosition(gesture.location(in: gesture.view!))
        case .ended:
            collection.endInteractiveMovement()
        default:
            collection.cancelInteractiveMovement()
        }
    }
    
    // MARK: - Constraints setup
    fileprivate func makeConstraints() {
        collection.snp.makeConstraints { make in
            make.edges.equalTo(self.view.safeAreaLayoutGuide.snp.edges)
        }
        
        ddgLogo.snp.makeConstraints { make in
            make.top.left.bottom.equalTo(0)
            make.size.equalTo(38)
        }
        
        ddgLabel.snp.makeConstraints { make in
            make.top.right.bottom.equalTo(0)
            make.left.equalTo(self.ddgLogo.snp.right).offset(5)
            make.width.equalTo(180)
            make.centerY.equalTo(self.ddgLogo)
        }
    }
    
    override func viewSafeAreaInsetsDidChange() {
        // Not sure why but when a side panel is opened and you transition from portait to landscape
        // top site cells are misaligned, this is a workaroud for this edge case. Happens only on iPhoneX.
        let isIphoneX = UIScreen.main.nativeBounds.height == 2436
        
        if isIphoneX {
            collection.snp.remakeConstraints { make in
                make.top.equalTo(self.view.safeAreaLayoutGuide.snp.top)
                make.bottom.equalTo(self.view.safeAreaLayoutGuide.snp.bottom)
                make.leading.equalTo(self.view.safeAreaLayoutGuide.snp.leading)
                make.trailing.equalTo(self.view.safeAreaLayoutGuide.snp.trailing).offset(self.view.safeAreaInsets.right)
            }
        }
    }
    
    // MARK: - Private browsing modde
    @objc func privateBrowsingModeChanged() {
        let isPrivateBrowsing = PrivateBrowsingManager.shared.isPrivateBrowsing
        
        // TODO: This entire blockshould be abstracted
        //  to make code in this class DRY (duplicates from elsewhere)
        collection.backgroundColor = isPrivateBrowsing ? UX.HomePanel.BackgroundColorPBM : UX.HomePanel.BackgroundColor
        braveShieldStatsView.timeStatView.color = isPrivateBrowsing ? UX.GreyA : UX.GreyJ
        collection.reloadData()
        updateDuckDuckGoVisibility()
    }
    
    @objc func showPrivateTabInfo() {
        let url = URL(string: "https://github.com/brave/browser-laptop/wiki/What-a-Private-Tab-actually-does")!
        DispatchQueue.main.async {
            // BRAVE TODO:
            // let t = getApp().tabManager
            // _ = t?.addTabAndSelect(URLRequest(url: url))
        }
    }
    
    // MARK: DuckDuckGo
    
    func shouldShowDuckDuckGoCallout() -> Bool {
        let isSearchEngineSet = profile.searchEngines.defaultEngine(forType: .privateMode).shortName == OpenSearchEngine.EngineNames.duckDuckGo
        let isPrivateBrowsing = PrivateBrowsingManager.shared.isPrivateBrowsing
        return isPrivateBrowsing && !isSearchEngineSet
    }
    
    func updateDuckDuckGoVisibility() {
        let isVisible = shouldShowDuckDuckGoCallout()
        let heightOfCallout = ddgButton.systemLayoutSizeFitting(UILayoutFittingExpandedSize).height + (UI.searchEngineCalloutPadding * 2.0)
        collection.contentInset.bottom = isVisible ? heightOfCallout : 0
        ddgButton.isHidden = !isVisible
    }
}

// MARK: - Delegates
extension FavoritesViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let fav = dataSource.favoriteBookmark(at: indexPath)
        
        guard let urlString = fav?.url, let url = URL(string: urlString) else { return }
        
        delegate?.didSelectUrl(url: url)
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collection.frame.width
        let padding: CGFloat = traitCollection.horizontalSizeClass == .compact ? 6 : 20
        
        let cellWidth = floor(width - padding) / CGFloat(columnsPerRow)
        // The tile's height is determined the aspect ratio of the thumbnails width. We also take into account
        // some padding between the title and the image.
        let cellHeight = floor(cellWidth / (CGFloat(FavoriteCell.imageAspectRatio) - 0.1))
        
        return CGSize(width: cellWidth, height: cellHeight)
    }
    
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let favoriteCell = cell as? FavoriteCell else { return }
        favoriteCell.delegate = self
    }
    
    fileprivate var columnsPerRow: Int {
        let size = collection.bounds.size
        let traitCollection = collection.traitCollection
        var cols = 0
        if traitCollection.horizontalSizeClass == .compact {
            // Landscape iPhone
            if traitCollection.verticalSizeClass == .compact {
                cols = 5
            }
                // Split screen iPad width
            else if size.widthLargerOrEqualThanHalfIPad() {
                cols = 4
            }
                // iPhone portrait
            else {
                cols = 3
            }
        } else {
            // Portrait iPad
            if size.height > size.width {
                cols = 4
            }
                // Landscape iPad
            else {
                cols = 5
            }
        }
        return cols + 1
    }
}

extension FavoritesViewController: FavoriteCellDelegate {
    func editFavorite(_ favoriteCell: FavoriteCell) {
        guard let indexPath = collection.indexPath(for: favoriteCell),
            let fav = dataSource.frc?.fetchedObjects?[indexPath.item] else { return }
        
        let actionSheet = UIAlertController(title: fav.displayTitle, message: nil, preferredStyle: .actionSheet)
        
        let deleteAction = UIAlertAction(title: Strings.Remove_Favorite, style: .destructive) { _ in
            fav.remove(save: true)
            
            // Remove cached icon.
            if let urlString = fav.url, let url = URL(string: urlString) {
                ImageCache.shared.remove(url, type: .square)
            }
            
            self.dataSource.isEditing = false
        }
        
        let editAction = UIAlertAction(title: Strings.Edit_Favorite, style: .default) { _ in
            guard let title = fav.displayTitle, let urlString = fav.url else { return }
            
            let editPopup = UIAlertController.userTextInputAlert(title: Strings.Edit_Bookmark, message: urlString,
                                                                 startingText: title, startingText2: fav.url,
                                                                 placeholder2: urlString,
                                                                 keyboardType2: .URL) { callbackTitle, callbackUrl in
                                                                    if let cTitle = callbackTitle, !cTitle.isEmpty, let cUrl = callbackUrl, !cUrl.isEmpty {
                                                                        if URL(string: cUrl) != nil {
                                                                            fav.update(customTitle: cTitle, url: cUrl, save: true)
                                                                        }
                                                                    }
                                                                    self.dataSource.isEditing = false
            }
            
            self.present(editPopup, animated: true)
        }
        
        let cancelAction = UIAlertAction(title: Strings.Cancel, style: .cancel, handler: nil)
        
        actionSheet.addAction(editAction)
        actionSheet.addAction(deleteAction)
        actionSheet.addAction(cancelAction)
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            actionSheet.popoverPresentationController?.permittedArrowDirections = .any
            actionSheet.popoverPresentationController?.sourceView = favoriteCell
            actionSheet.popoverPresentationController?.sourceRect = favoriteCell.bounds
            present(actionSheet, animated: true)
        } else {
            present(actionSheet, animated: true) {
                self.dataSource.isEditing = false
            }
        }
    }
}

extension CGSize {
    public func widthLargerOrEqualThanHalfIPad() -> Bool {
        let halfIPadSize: CGFloat = 507
        return width >= halfIPadSize
    }
}
