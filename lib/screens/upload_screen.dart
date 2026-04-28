import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';
import '../models/auth_response.dart';

class UploadScreen extends StatefulWidget {
  @override
  _UploadScreenState createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  final ApiService _apiService = ApiService();
  AuthResponse? _authData;
  bool _isLoading = false;

  // Fonction pour se connecter (Utilise un compte créé dans l'admin Strapi)
  void _handleLogin() async {
    setState(() => _isLoading = true);
    final result = await _apiService.login("test@gmail.com", "password123");
    setState(() {
      _authData = result;
      _isLoading = false;
    });
    if (result != null) print("Connecté ! JWT: ${result.jwt}");
  }

  // Fonction pour choisir et envoyer le fichier
  void _handleUpload() async {
    if (_authData == null) return;

    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio);
    
    if (result != null) {
      setState(() => _isLoading = true);
      File file = File(result.files.single.path!);
      
      bool success = await _apiService.uploadAudio(_authData!.jwt, file);
      
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? "Upload réussi !" : "Échec de l'upload")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Test MinIO & Strapi")),
      body: Center(
        child: _isLoading 
          ? CircularProgressIndicator() 
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_authData == null)
                  ElevatedButton(onPressed: _handleLogin, child: Text("1. Se connecter")),
                if (_authData != null) ...[
                  Text("Utilisateur ID: ${_authData!.userId}"),
                  SizedBox(height: 20),
                  ElevatedButton(onPressed: _handleUpload, child: Text("2. Choisir & Uploader l'audio")),
                ]
              ],
            ),
      ),
    );
  }
}