import SwiftUI

/// A table on the left and a scrollable timeline on the right, with vertical scrolling kept in sync —
/// the layout shared by the Gantt chart and the resource usage grid.
///
/// The timeline only draws the visible part of the chart, so huge projects don't allocate huge layers.
struct TimelineSplitView<LeftHeader: View, LeftRow: View, ChartHeader: View>: View {
    let rowCount: Int
    let rowHeight: CGFloat
    let contentWidth: CGFloat
    @Binding var leftWidth: CGFloat
    var minLeftWidth: CGFloat = 140
    @ViewBuilder let leftHeader: () -> LeftHeader
    @ViewBuilder let leftRow: (Int) -> LeftRow
    /// The header above the chart, given the chart's horizontal scroll offset.
    @ViewBuilder let chartHeader: (CGFloat) -> ChartHeader
    let drawChart: (inout GraphicsContext, CGRect) -> Void
    var onChartTap: ((CGPoint, Int) -> Void)?
    var onChartDrag: ChartDragHandler?
    /// Horizontal position to show first (e.g. just before the project start).
    var initialX: CGFloat = 0
    /// Horizontal scale (e.g. pixels per day). When it changes, the date at the left edge stays put.
    var zoom: CGFloat = 1

    static var headerHeight: CGFloat { 44 }

    @State private var leftPosition = ScrollPosition(idType: Int.self)
    @State private var chartPosition = ScrollPosition(idType: Int.self)
    @State private var leftOffsetY: CGFloat = 0
    @State private var chartOffset: CGPoint = .zero
    @State private var chartViewport: CGSize = .zero
    @State private var dragStartWidth: CGFloat?

    private var contentHeight: CGFloat { CGFloat(rowCount) * rowHeight }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: leftWidth)
            divider
            chartPane
        }
    }

    private var leftPane: some View {
        VStack(spacing: 0) {
            leftHeader()
                .frame(width: leftWidth, height: Self.headerHeight, alignment: .leading)
                .clipped()
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<rowCount, id: \.self) { index in
                        leftRow(index)
                            .frame(width: leftWidth, height: rowHeight, alignment: .leading)
                            .clipped()
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollPosition($leftPosition)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                leftOffsetY = y
                if abs(y - chartOffset.y) > 0.5 {
                    chartPosition.scrollTo(point: CGPoint(x: chartOffset.x, y: y))
                }
            }
        }
        .clipped()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .onHover { inside in
                        if inside { NSCursor.columnResize.push() } else { NSCursor.pop() }
                    }
                    #endif
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? leftWidth
                                dragStartWidth = start
                                leftWidth = max(minLeftWidth, start + value.translation.width)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
    }

    private var chartPane: some View {
        VStack(spacing: 0) {
            chartHeader(chartOffset.x)
                .frame(height: Self.headerHeight)
                .clipped()
            ScrollView([.horizontal, .vertical]) {
                chartContent
                    .padding(.bottom, 40)
            }
            .scrollPosition($chartPosition)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .onAppear { chartPosition.scrollTo(x: max(initialX, 0)) }
            .onChange(of: zoom) { old, new in
                guard old > 0 else { return }
                chartPosition.scrollTo(point: CGPoint(x: max(chartOffset.x * new / old, 0), y: chartOffset.y))
            }
            .onScrollGeometryChange(for: ScrollSnapshot.self, of: {
                ScrollSnapshot(offset: $0.contentOffset, size: $0.containerSize)
            }) { _, snapshot in
                chartOffset = snapshot.offset
                chartViewport = snapshot.size
                if abs(snapshot.offset.y - leftOffsetY) > 0.5 {
                    leftPosition.scrollTo(y: snapshot.offset.y)
                }
            }
        }
    }

    private var visibleRect: CGRect {
        let full = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        let viewport = CGRect(origin: chartOffset, size: chartViewport == .zero ? CGSize(width: 1200, height: 900) : chartViewport)
        return viewport.intersection(full).isNull ? CGRect(origin: .zero, size: CGSize(width: 1, height: 1)) : viewport.intersection(full)
    }

    private var chartContent: some View {
        let visible = visibleRect
        // Same height as the table so both sides scroll the same distance.
        let height = contentHeight
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: contentWidth, height: height)
            Canvas { context, _ in
                context.translateBy(x: -visible.minX, y: -visible.minY)
                drawChart(&context, visible)
            }
            .frame(width: visible.width, height: visible.height)
            .offset(x: visible.minX, y: visible.minY)
            .allowsHitTesting(false)
        }
        // The canvas is offset inside; pin the content size so it can't grow the scrollable area.
        .frame(width: contentWidth, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { location in
            let row = Int(location.y / rowHeight)
            onChartTap?(location, row)
        }
        #if os(macOS)
        .gesture(dragGesture)
        #endif
    }

    #if os(macOS)
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in onChartDrag?.changed(value.startLocation, value.translation.width) }
            .onEnded { value in onChartDrag?.ended(value.startLocation, value.translation.width) }
    }
    #endif
}

struct ChartDragHandler {
    var changed: (CGPoint, CGFloat) -> Void
    var ended: (CGPoint, CGFloat) -> Void
}

private struct ScrollSnapshot: Equatable {
    var offset: CGPoint
    var size: CGSize
}
