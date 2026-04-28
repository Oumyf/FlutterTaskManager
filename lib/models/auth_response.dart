class AuthResponse {
  final String jwt;
  final int userId;

  AuthResponse({required this.jwt, required this.userId});

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    return AuthResponse(
      jwt: json['jwt'],
      userId: json['user']['id'],
    );
  }
}