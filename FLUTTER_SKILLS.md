# Montée en compétences Flutter — Tasks Manager

> Projet : application de gestion de tâches (style Trello)
> Stack : Flutter + Firebase + Isar + Material Design 3

---

## Ce que tu as appris dans ce projet

### 1. Structure d'une app Flutter

- **`main.dart`** : point d'entrée, initialisation Firebase, routing
- **`MaterialApp`** + `ThemeData` : configuration du thème global
- **`Scaffold`** : structure de base de chaque écran (AppBar + body + bottomNav)
- **`NavigationBar`** + `NavigationDestination` : barre de navigation moderne (Material 3)

```dart
// Pattern classique : index de page + setState
int _currentPage = 0;
onDestinationSelected: (i) => setState(() => _currentPage = i),
```

---

### 2. Widgets de mise en page

| Widget | Rôle |
|--------|------|
| `Column` / `Row` | Disposition verticale / horizontale |
| `Stack` | Superposition de widgets |
| `Expanded` | Remplit l'espace disponible (obligatoire dans Row/Column) |
| `Flexible` | Comme Expanded mais peut rétrécir |
| `Padding` / `SizedBox` | Espacement |
| `SingleChildScrollView` | Rendre un contenu scrollable |
| `ListView.builder` | Liste performante avec items générés dynamiquement |
| `Wrap` | Aligne les enfants en revenant à la ligne si nécessaire |

> **Erreur classique** : mettre un `ListView` dans un `Column` sans `Expanded` → RenderFlex overflow

---

### 3. Formulaires et validation

```dart
Form(
  key: _formKey,
  autovalidateMode: _autoValidateMode,
  child: Column(children: [
    TextFormField(
      controller: _titleController,
      validator: (v) => (v?.trim().isEmpty ?? true) ? 'Requis' : null,
    ),
  ]),
)

// Valider manuellement
final isValid = _formKey.currentState?.validate() ?? false;
```

- **`TextEditingController`** : lire/écrire le texte d'un champ
- **`autovalidateMode`** : quand déclencher la validation (onUserInteraction, always, disabled)
- **`DropdownButtonFormField`** : toujours ajouter `isExpanded: true` pour éviter l'overflow

---

### 4. Navigation entre pages

```dart
// Pousser une nouvelle page
Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage()));

// Revenir
Navigator.pop(context);

// Remplacer la page courante
Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => LoginPage()));
```

- **`StreamBuilder<User?>`** : écoute en temps réel l'état Firebase Auth → redirige automatiquement

---

### 5. État local avec setState

```dart
class _MyPageState extends State<MyPage> {
  int count = 0;

  void increment() {
    setState(() => count++); // rebuild du widget
  }
}
```

> `setState` ne rebuild que le widget et ses enfants — pas toute l'app.

---

### 6. Gestion asynchrone (async/await)

```dart
Future<void> loadData() async {
  final result = await isarService.getAllTasks();
  setState(() => tasks = result);
}
```

- **`Future`** : opération qui complètera dans le futur
- **`async/await`** : syntaxe pour attendre un Future sans bloquer l'UI
- **`mounted`** : toujours vérifier avant d'appeler setState après un await

```dart
if (mounted) setState(() => _loading = false);
```

---

### 7. Base de données locale — Isar

```dart
@collection
class Task {
  Id id = Isar.autoIncrement;
  late String title;
  String? description; // nullable = optionnel
}
```

- **`@collection`** : marque la classe comme une table Isar
- **`Id`** : clé primaire auto-incrémentée
- **`build_runner`** : génère le fichier `.g.dart` (schéma Isar)
- **Opérations CRUD** :
  ```dart
  await isar.writeTxn(() => isar.tasks.put(task));   // create/update
  await isar.tasks.where().findAll();                 // read
  await isar.writeTxn(() => isar.tasks.delete(id));  // delete
  ```

> **Important** : changer le schéma (ajouter un champ) nécessite de relancer `build_runner`

---

### 8. Firebase Auth

```dart
// Connexion email/password
await FirebaseAuth.instance.signInWithEmailAndPassword(
  email: email, password: password);

// Écouter l'état de connexion
stream: FirebaseAuth.instance.authStateChanges()
// → null si déconnecté, User si connecté
```

- **Google Sign-In** : nécessite SHA-1 dans Firebase Console pour Android
- **`StreamBuilder<User?>`** : widget qui se rebuild à chaque changement d'état auth

---

### 9. Drag & Drop (Kanban)

```dart
// Widget draggable
LongPressDraggable<Task>(
  data: task,           // données transportées
  feedback: CardWidget(), // widget affiché pendant le drag
  child: CardWidget(),
)

// Zone de dépôt
DragTarget<Task>(
  onWillAcceptWithDetails: (_) => true,
  onAcceptWithDetails: (details) => moveTask(details.data),
  builder: (context, candidateData, _) { ... }
)
```

> **Piège** : utiliser `SingleChildScrollView` horizontal plutôt que `ListView` pour ne pas capturer les gestes de drag.

---

### 10. Animations

```dart
// Animation simple sur changement de valeur
AnimatedContainer(
  duration: Duration(milliseconds: 200),
  color: isSelected ? Colors.blue : Colors.grey,
)

// AnimationController pour animations en boucle
late AnimationController _controller;
_controller = AnimationController(vsync: this, duration: Duration(ms: 800))
  ..repeat(reverse: true);
```

- **`SingleTickerProviderStateMixin`** : requis pour `AnimationController`
- **`AnimatedSwitcher`** : transition automatique entre 2 widgets
- **`AnimatedBuilder`** : rebuild uniquement la partie animée

---

### 11. Médias

```dart
// Choisir une image
final f = await ImagePicker().pickImage(source: ImageSource.gallery);

// Afficher une image locale
Image.file(File(path), height: 100, fit: BoxFit.cover)

// Enregistrer audio
await recorder.start(path: path, encoder: AudioEncoder.wav);
await recorder.stop();

// Lire audio
final player = AudioPlayer();
await player.setFilePath(path);
await player.play();
```

---

### 12. SharedPreferences (persistance légère)

```dart
// Sauvegarder
final prefs = await SharedPreferences.getInstance();
await prefs.setString('key', value);

// Lire
final value = prefs.getString('key') ?? '';
```

> Utiliser pour : URL serveur, image de fond, préférences utilisateur.

---

### 13. Notifications locales

```dart
// Afficher une notification immédiate
await flutterLocalNotifications.show(id, title, body, details);

// Notification programmée (timezone)
await flutterLocalNotifications.zonedSchedule(
  id, title, body,
  tz.TZDateTime.from(scheduledDate, tz.local),
  details,
);
```

---

### 14. HTTP / API REST

```dart
// Requête multipart (envoyer un fichier)
final request = http.MultipartRequest('POST', Uri.parse(url))
  ..files.add(await http.MultipartFile.fromPath('file', audioPath));
final response = await request.send();
final body = await response.stream.bytesToString();
```

---

## Concepts Flutter importants à retenir

### `const` vs `final` vs `var`
```dart
const text = 'Fixe à la compilation';  // valeur connue avant l'exécution
final name = fetchName();               // assigné une seule fois, au runtime
var count = 0;                          // peut changer
```

### Nullable vs Non-nullable
```dart
String  title;   // ne peut jamais être null
String? subtitle; // peut être null → toujours vérifier avant d'utiliser
subtitle?.length  // safe call — retourne null si subtitle est null
subtitle ?? ''    // valeur par défaut si null
```

### `StatelessWidget` vs `StatefulWidget`
| | StatelessWidget | StatefulWidget |
|---|---|---|
| État interne | Non | Oui |
| `setState` | Non | Oui |
| Performance | Meilleure | Légèrement plus lourde |
| Utiliser quand | Affichage statique | Formulaire, animation, données changeantes |

### Le cycle de vie d'un StatefulWidget
```dart
@override
void initState() {
  super.initState();
  // appelé une seule fois à la création
}

@override
void dispose() {
  controller.dispose(); // toujours libérer les ressources
  super.dispose();
}
```

---

## Erreurs fréquentes et solutions

| Erreur | Cause | Solution |
|--------|-------|----------|
| `RenderFlex overflowed` | Pas assez de place dans Row/Column | Entourer l'enfant avec `Expanded` |
| `setState after dispose` | Async complète après fermeture du widget | Vérifier `if (mounted)` |
| `Null check on null` | Accès à un champ nullable sans vérification | Utiliser `?.` ou `??` |
| `IsarError: Collection id invalid` | Schéma modifié sans relancer build_runner | `dart run build_runner build --delete-conflicting-outputs` |
| `Instance already opened` | Isar ouvert deux fois | Vérifier `Isar.instanceNames.isNotEmpty` avant d'ouvrir |
| `Google Sign-In error 10` | SHA-1 non enregistré dans Firebase | Ajouter le SHA-1 dans Firebase Console |

---

## Prochaines étapes recommandées

1. **Provider / Riverpod** : gestion d'état globale (remplacer `setState` par quelque chose de plus scalable)
2. **Firestore** : base de données cloud pour synchroniser entre utilisateurs (pour les assignations)
3. **GoRouter** : navigation avancée avec URL et deep linking
4. **Tests unitaires** : `flutter_test`, tester les services et la logique métier
5. **CI/CD** : GitHub Actions pour build automatique + deploy sur Play Store
6. **Internationalisation (i18n)** : `flutter_localizations` pour supporter plusieurs langues

---

## Ressources

- Documentation Flutter : https://docs.flutter.dev
- Pub.dev (packages) : https://pub.dev
- Firebase Flutter : https://firebase.google.com/docs/flutter/setup
- Material Design 3 : https://m3.material.io
- Isar Database : https://isar.dev
