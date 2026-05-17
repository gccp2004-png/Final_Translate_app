import 'package:flutter/material.dart';
import 'lang_option.dart';

class LangDropdown extends StatelessWidget {
  final LangOption value;
  final List<LangOption> items;
  final ValueChanged<LangOption?> onChanged;
  final bool showBoth;

  const LangDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.showBoth = false,
  });

  String _label(LangOption l) {
    return showBoth ? '${l.englishLabel} / ${l.nativeLabel}' : l.englishLabel;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<LangOption>(
          isExpanded: true,
          value: value,
          dropdownColor: const Color(0xFF121826),
          items: items.map((l) {
            return DropdownMenuItem<LangOption>(
              value: l,
              child: Text(
                _label(l),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white),
              ),
            );
          }).toList(),
          onChanged: onChanged,
          iconEnabledColor: Colors.white.withOpacity(0.8),
        ),
      ),
    );
  }
}