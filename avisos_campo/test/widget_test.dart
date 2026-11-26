// El test anterior era la plantilla del contador de Flutter y fallaba siempre
// (esta app no tiene contador y MapaAvisosScreen necesita Firebase).
// Este comprueba que la pantalla de login se dibuja sin depender de Firebase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:avisos_campo/main.dart';

void main() {
  testWidgets('La pantalla de login muestra los campos y alterna a registro', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

    expect(find.text('Correo Electrónico'), findsOneWidget);
    expect(find.text('Contraseña'), findsOneWidget);
    expect(find.text('Iniciar Sesión'), findsOneWidget);

    await tester.tap(find.text('No tengo cuenta. Registrarse'));
    await tester.pump();

    expect(find.text('Registrarse'), findsOneWidget);
  });
}
