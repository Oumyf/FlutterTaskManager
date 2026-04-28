import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/auth_service.dart';

const _primary = Color(0xFF6366F1);
const _red     = Color(0xFFEF4444);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _prefBgKey = 'board_background_path';

  String? _boardBgPath;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _boardBgPath = prefs.getString(_prefBgKey);
    });
  }

  Future<void> _pickBackground() async {
    final f = await _picker.pickImage(source: ImageSource.gallery);
    if (f == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefBgKey, f.path);
    setState(() => _boardBgPath = f.path);
    if (mounted) _snack('Image de fond mise à jour');
  }

  Future<void> _removeBackground() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefBgKey);
    setState(() => _boardBgPath = null);
    if (mounted) _snack('Image de fond supprimée');
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: _primary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Se déconnecter ?'),
        content: const Text('Vous serez redirigé vers la page de connexion.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _red),
            onPressed: () async {
              Navigator.pop(context);
              await AuthService.instance.signOut();
            },
            child: const Text('Déconnecter'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Profil ────────────────────────────────────────────────────────
          _section('Profil', [
            _tile(
              icon: Icons.person_outline,
              iconColor: _primary,
              title: AuthService.instance.userName,
              subtitle: AuthService.instance.userEmail,
              trailing: const SizedBox.shrink(),
            ),
          ]),

          const SizedBox(height: 16),

          // ── Apparence ─────────────────────────────────────────────────────
          _section('Apparence', [
            _tile(
              icon: Icons.wallpaper_rounded,
              iconColor: const Color(0xFF8B5CF6),
              title: 'Image de fond du Board',
              subtitle: _boardBgPath != null
                  ? 'Image sélectionnée'
                  : 'Aucune image',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_boardBgPath != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: _red, size: 20),
                    onPressed: _removeBackground,
                    tooltip: 'Supprimer',
                  ),
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined,
                      color: _primary, size: 20),
                  onPressed: _pickBackground,
                  tooltip: 'Choisir une image',
                ),
              ]),
            ),
          ]),

          const SizedBox(height: 16),

          // ── Compte ────────────────────────────────────────────────────────
          _section('Compte', [
            _tile(
              icon: Icons.logout_rounded,
              iconColor: _red,
              title: 'Se déconnecter',
              subtitle: 'Retour à l\'écran de connexion',
              titleColor: _red,
              onTap: _confirmLogout,
            ),
          ]),

          const SizedBox(height: 32),

          // Version
          Center(
            child: Text(
              'Tasks Manager v1.0',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
          ),
        ],
    );
  }

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey[500],
                    letterSpacing: 1.2)),
          ),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(children: children),
          ),
        ],
      );

  Widget _tile({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    Color? titleColor,
    VoidCallback? onTap,
  }) =>
      ListTile(
        onTap: onTap,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        title: Text(title,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: titleColor ?? Colors.black87)),
        subtitle: subtitle != null
            ? Text(subtitle,
                style: TextStyle(fontSize: 12, color: Colors.grey[500]))
            : null,
        trailing: trailing ??
            (onTap != null
                ? const Icon(Icons.chevron_right, color: Colors.grey)
                : null),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      );
}
