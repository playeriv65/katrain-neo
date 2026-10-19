// What the main screen shows: the board's analysis layers and the panels of the right column, kept per mode.

/// A collapsable panel of the right column: open or closed, and which of its tabs are on.
class PanelState {
  String state;
  final Map<String, bool> options;
  PanelState(this.state, this.options);

  bool get open => state == 'open';

  List<Object> toJson() => [state, Map.of(options)];
}

/// The board's analysis layers and the panels, as they start (each mode then keeps its own, see `ui_state`).
Map<String, bool> defaultAnalysisControls() => {
  'show_children': true,
  'eval': false,
  'hints': false,
  'policy': false,
  'ownership': false,
};

Map<String, PanelState> defaultPanels() => {
  'graph_panel': PanelState('open', {'score': true, 'winrate': false, 'points': false}),
  'stats_panel': PanelState('open', {'score': true, 'winrate': true, 'points': true}),
  'notes_panel': PanelState('open', {'info': true, 'info-details': false, 'notes': false}),
};
