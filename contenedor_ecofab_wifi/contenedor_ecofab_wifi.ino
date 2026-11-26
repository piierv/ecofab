/*
  EcoFab Lab – Contenedor inteligente con envío a Supabase por WiFi
  Placa: ESP32 DevKit
  Sensor: HC-SR04 (ultrasónico) montado en la tapa, apuntando hacia abajo
  Pantalla: OLED 0.96" SSD1306 I2C (128x64)
  Librerías: "Adafruit SSD1306" y "Adafruit GFX" (Gestor de librerías del Arduino IDE)

  Cada 10 s (o antes si el nivel cambia 2 % o más) envía la lectura a Supabase,
  y el panel de gestión la muestra en vivo. También sigue imprimiendo JSON por Serial.
  Requiere una placa ESP32: el Arduino UNO no tiene WiFi.
*/

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ---------- WiFi y Supabase (AJUSTAR) ----------
const char* WIFI_SSID     = "NOMBRE-DE-TU-WIFI";     // red de 2,4 GHz (el ESP32 no usa 5 GHz)
const char* WIFI_PASS     = "CLAVE-DE-TU-WIFI";
const char* SUPABASE_URL  = "https://TU-PROYECTO.supabase.co";
const char* SUPABASE_KEY  = "TU-CLAVE-ANON-O-PUBLISHABLE";
const char* DISPOSITIVO   = "esp32-a";
const char* TOKEN_SENSOR  = "CAMBIA-ESTE-TOKEN";      // el mismo que pusiste en esquema.sql
const unsigned long CADA_MS = 10000;                  // envío periódico
const int CAMBIO_MIN = 2;                             // o antes, si cambia 2 % o más

// ---------- Configuración del contenedor (AJUSTAR) ----------
const char* ID_CONTENEDOR = "A";   // A, B, C o D como en la app
float DIST_VACIO_CM = 30.0;        // distancia sensor→fondo con el contenedor vacío (medirla con el monitor serie)
const float DIST_LLENO_CM = 4.0;   // distancia que se considera 100 % (no bajar de ~3 cm: zona ciega del sensor)
const int UMBRAL_AVISO  = 80;      // mismos umbrales que la app
const int UMBRAL_RETIRO = 95;

// ---------- Pines ESP32 ----------
const int PIN_TRIG     = 5;
const int PIN_ECHO     = 18;   // ¡con divisor de voltaje si el HC-SR04 va a 5 V!
const int LED_VERDE    = 25;
const int LED_AMARILLO = 26;
const int LED_ROJO     = 27;
const int PIN_BUZZER   = 14;   // buzzer ACTIVO (opcional)

Adafruit_SSD1306 oled(128, 64, &Wire, -1);

float pctSuave = -1;           // porcentaje filtrado
String estadoAnterior = "";
unsigned long ultimoEnvio = 0;
int ultimoPctEnviado = -100;
bool ultimoEnvioOk = false;

void conectarWiFi() {
  if (WiFi.status() == WL_CONNECTED) return;
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 8000) delay(250);
  Serial.println(WiFi.status() == WL_CONNECTED ? "{\"wifi\":\"ok\"}" : "{\"wifi\":\"sin_conexion\"}");
}

bool enviarLectura(int pct, float dist) {
  if (WiFi.status() != WL_CONNECTED) return false;
  WiFiClientSecure cliente;
  cliente.setInsecure();   // suficiente para el prototipo; en producción, cargar el certificado raíz
  HTTPClient http;
  String url = String(SUPABASE_URL) + "/rest/v1/rpc/registrar_lectura";
  if (!http.begin(cliente, url)) return false;
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_KEY);
  String body = String("{\"p_dispositivo\":\"") + DISPOSITIVO + "\",\"p_token\":\"" + TOKEN_SENSOR +
                "\",\"p_pct\":" + pct + ",\"p_dist\":" + String(dist, 1) + "}";
  int code = http.POST(body);
  if (code != 200 && code != 204) {
    Serial.print("{\"envio\":\"error\",\"http\":"); Serial.print(code);
    Serial.print(",\"detalle\":"); Serial.print("\""); Serial.print(http.getString()); Serial.println("\"}");
  }
  http.end();
  return code == 200 || code == 204;
}

// Una lectura del sensor en cm (-1 si no hubo eco)
float medirUnaVez() {
  digitalWrite(PIN_TRIG, LOW);  delayMicroseconds(2);
  digitalWrite(PIN_TRIG, HIGH); delayMicroseconds(10);
  digitalWrite(PIN_TRIG, LOW);
  unsigned long us = pulseIn(PIN_ECHO, HIGH, 30000);
  return us == 0 ? -1 : us / 58.0;
}

// Mediana de 5 lecturas: ignora picos (por ejemplo, una mano que pasa)
float medirMediana() {
  float v[5]; int n = 0;
  for (int i = 0; i < 5; i++) {
    float d = medirUnaVez();
    if (d > 0) v[n++] = d;
    delay(40);
  }
  if (n == 0) return -1;
  for (int i = 0; i < n - 1; i++)
    for (int j = i + 1; j < n; j++)
      if (v[j] < v[i]) { float t = v[i]; v[i] = v[j]; v[j] = t; }
  return v[n / 2];
}

int porcentaje(float d) {
  float p = (DIST_VACIO_CM - d) / (DIST_VACIO_CM - DIST_LLENO_CM) * 100.0;
  return constrain((int)round(p), 0, 100);
}

String estadoDe(int pct) {
  if (pct >= UMBRAL_RETIRO) return "retiro";
  if (pct >= UMBRAL_AVISO)  return "aviso";
  return "ok";
}

void actualizarLeds(const String& e) {
  digitalWrite(LED_VERDE,    e == "ok");
  digitalWrite(LED_AMARILLO, e == "aviso");
  digitalWrite(LED_ROJO,     e == "retiro");
}

void dibujarPantalla(int pct, const String& e, bool errorSensor) {
  oled.clearDisplay();
  oled.setTextColor(SSD1306_WHITE);

  oled.setTextSize(1);
  oled.setCursor(0, 0);
  oled.print("EcoFab Lab  Cont. ");
  oled.print(ID_CONTENEDOR);
  oled.setCursor(110, 0);
  oled.print(WiFi.status() == WL_CONNECTED ? (ultimoEnvioOk ? "ok" : "wf") : "--");
  oled.drawLine(0, 10, 127, 10, SSD1306_WHITE);

  if (errorSensor) {
    oled.setTextSize(2);
    oled.setCursor(0, 28);
    oled.print("Sin lectura");
    oled.display();
    return;
  }

  // Porcentaje grande
  oled.setTextSize(3);
  oled.setCursor(0, 16);
  oled.print(pct);
  oled.print("%");

  // Estado a la derecha
  oled.setTextSize(1);
  oled.setCursor(80, 18);
  if (e == "ok")     oled.print("OK");
  if (e == "aviso")  { oled.print("Casi"); oled.setCursor(80, 28); oled.print("lleno"); }
  if (e == "retiro") { oled.print("RETIRAR"); }

  // Barra de llenado
  oled.drawRect(0, 48, 128, 14, SSD1306_WHITE);
  oled.fillRect(2, 50, map(pct, 0, 100, 0, 124), 10, SSD1306_WHITE);
  // Marcas de 80 % y 95 %
  oled.drawLine(2 + 124 * UMBRAL_AVISO / 100, 45, 2 + 124 * UMBRAL_AVISO / 100, 47, SSD1306_WHITE);
  oled.drawLine(2 + 124 * UMBRAL_RETIRO / 100, 45, 2 + 124 * UMBRAL_RETIRO / 100, 47, SSD1306_WHITE);

  oled.display();
}

void pitido(int veces) {
  for (int i = 0; i < veces; i++) {
    digitalWrite(PIN_BUZZER, HIGH); delay(150);
    digitalWrite(PIN_BUZZER, LOW);  delay(120);
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_TRIG, OUTPUT);
  pinMode(PIN_ECHO, INPUT);
  pinMode(LED_VERDE, OUTPUT);
  pinMode(LED_AMARILLO, OUTPUT);
  pinMode(LED_ROJO, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);

  if (!oled.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {   // si no enciende, probar 0x3D
    Serial.println("{\"error\":\"oled\"}");
  }
  oled.clearDisplay();
  oled.setTextSize(1);
  oled.setTextColor(SSD1306_WHITE);
  oled.setCursor(0, 24);
  oled.print("Conectando WiFi...");
  oled.display();
  conectarWiFi();
}

void loop() {
  float d = medirMediana();

  if (d < 0) {
    dibujarPantalla(0, "ok", true);
    Serial.println("{\"bin\":\"" + String(ID_CONTENEDOR) + "\",\"error\":\"sensor\"}");
    delay(1000);
    return;
  }

  int pct = porcentaje(d);
  // Suavizado: cambia de a poco para que no salte al echar un residuo
  pctSuave = (pctSuave < 0) ? pct : 0.7 * pctSuave + 0.3 * pct;
  int pctMostrar = (int)round(pctSuave);
  String e = estadoDe(pctMostrar);

  actualizarLeds(e);
  dibujarPantalla(pctMostrar, e, false);

  // Pitido solo al cruzar un umbral, no todo el rato
  if (e != estadoAnterior) {
    if (e == "aviso")  pitido(1);
    if (e == "retiro") pitido(3);
    estadoAnterior = e;
  }

  // Envío a Supabase: cada CADA_MS o si el nivel cambió bastante
  bool cambio = abs(pctMostrar - ultimoPctEnviado) >= CAMBIO_MIN;
  if (cambio || millis() - ultimoEnvio >= CADA_MS) {
    conectarWiFi();
    ultimoEnvioOk = enviarLectura(pctMostrar, d);
    ultimoEnvio = millis();
    if (ultimoEnvioOk) ultimoPctEnviado = pctMostrar;
  }

  // Línea JSON por Serial (para depurar)
  Serial.print("{\"bin\":\"");  Serial.print(ID_CONTENEDOR);
  Serial.print("\",\"pct\":");  Serial.print(pctMostrar);
  Serial.print(",\"dist\":");   Serial.print(d, 1);
  Serial.print(",\"estado\":\""); Serial.print(e);
  Serial.println("\"}");

  delay(1000);
}
