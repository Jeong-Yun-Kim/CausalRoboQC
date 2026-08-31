#include <Arduino.h>
#include <Servo.h>
#include <stdlib.h>
#include <string.h>

const uint8_t SERVO_COUNT = 6;
const uint8_t SERVO_PINS[SERVO_COUNT] = {2, 3, 9, 8, 4, 5};

// Change these limits to match the safe mechanical range of each joint.
const int16_t SERVO_MIN[SERVO_COUNT] = {0, 0, 0, 0, 0, 0};
const int16_t SERVO_MAX[SERVO_COUNT] = {180, 180, 180, 180, 180, 180};

const uint32_t BAUD_RATE = 115200;
const uint16_t FIRST_MOVE_SETTLE_MS = 1500;
const uint16_t STEP_INTERVAL_MS = 25;  // 1 degree per step = 40 degrees/second
const uint8_t LINE_SIZE = 96;

Servo servos[SERVO_COUNT];
int16_t currentAngle[SERVO_COUNT] = {-1, -1, -1, -1, -1, -1};
int16_t targetAngle[SERVO_COUNT] = {-1, -1, -1, -1, -1, -1};
uint32_t settleUntil[SERVO_COUNT] = {0, 0, 0, 0, 0, 0};

uint8_t attachedMask = 0;
bool emergencyStopped = false;
bool doneRequested = false;
uint32_t lastStepAt = 0;

char lineBuffer[LINE_SIZE];
uint8_t lineLength = 0;
bool lineOverflow = false;

bool isAttached(uint8_t index) {
  return (attachedMask & (1U << index)) != 0;
}

bool timeNotReached(uint32_t deadline, uint32_t now) {
  return deadline != 0 && (int32_t)(deadline - now) > 0;
}

bool isMoving() {
  const uint32_t now = millis();
  for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
    if (!isAttached(i)) {
      continue;
    }
    if (currentAngle[i] != targetAngle[i] || timeNotReached(settleUntil[i], now)) {
      return true;
    }
  }
  return false;
}

bool parseInteger(const char *text, int16_t &value) {
  if (text == NULL || *text == '\0') {
    return false;
  }

  char *end = NULL;
  const long parsed = strtol(text, &end, 10);
  if (*end != '\0' || parsed < -32768L || parsed > 32767L) {
    return false;
  }

  value = (int16_t)parsed;
  return true;
}

void printError(const __FlashStringHelper *message) {
  Serial.print(F("ERR "));
  Serial.println(message);
}

void printLimits() {
  Serial.print(F("LIMITS"));
  for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
    Serial.print(' ');
    Serial.print(SERVO_MIN[i]);
    Serial.print(' ');
    Serial.print(SERVO_MAX[i]);
  }
  Serial.println();
}

void printStatus() {
  Serial.print(F("STATUS "));
  Serial.print(attachedMask);
  Serial.print(' ');
  Serial.print(isMoving() ? 1 : 0);
  Serial.print(' ');
  Serial.print(emergencyStopped ? 1 : 0);

  for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
    Serial.print(' ');
    Serial.print(currentAngle[i]);
  }
  for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
    Serial.print(' ');
    Serial.print(targetAngle[i]);
  }
  Serial.println();
}

void attachAtAngle(uint8_t index, int16_t angle) {
  // Preload the pulse width before attach, so Servo.attach() never outputs
  // the library's default 90-degree pulse.
  servos[index].write(angle);
  servos[index].attach(SERVO_PINS[index]);
  attachedMask |= (1U << index);
  currentAngle[index] = angle;
  targetAngle[index] = angle;
  settleUntil[index] = millis() + FIRST_MOVE_SETTLE_MS;
}

void setTarget(uint8_t index, int16_t angle) {
  if (!isAttached(index)) {
    attachAtAngle(index, angle);
    return;
  }
  targetAngle[index] = angle;
}

void stopMotion() {
  for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
    if (isAttached(i)) {
      targetAngle[i] = currentAngle[i];
    }
    settleUntil[i] = 0;
  }
  doneRequested = false;
}

void detachAll() {
  for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
    if (isAttached(i)) {
      servos[i].detach();
    }
    currentAngle[i] = -1;
    targetAngle[i] = -1;
    settleUntil[i] = 0;
  }
  attachedMask = 0;
  doneRequested = false;
}

void updateMotion() {
  const uint32_t now = millis();
  const uint32_t elapsed = now - lastStepAt;

  if (elapsed >= STEP_INTERVAL_MS) {
    uint32_t steps = elapsed / STEP_INTERVAL_MS;
    if (steps > 180U) {
      steps = 180U;
    }
    lastStepAt = now;

    for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
      if (!isAttached(i) || currentAngle[i] == targetAngle[i]) {
        continue;
      }

      int16_t difference = targetAngle[i] - currentAngle[i];
      int16_t amount = abs(difference);
      if (amount > (int16_t)steps) {
        amount = (int16_t)steps;
      }
      currentAngle[i] += difference > 0 ? amount : -amount;
      servos[i].write(currentAngle[i]);
    }
  }

  for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
    if (settleUntil[i] != 0 && !timeNotReached(settleUntil[i], now)) {
      settleUntil[i] = 0;
    }
  }

  if (doneRequested && !isMoving()) {
    doneRequested = false;
    Serial.println(F("DONE"));
  }
}

bool hasExtraToken() {
  return strtok(NULL, " \t") != NULL;
}

void handleSet() {
  if (emergencyStopped) {
    printError(F("ESTOP"));
    return;
  }

  char *servoText = strtok(NULL, " \t");
  char *angleText = strtok(NULL, " \t");
  int16_t servoNumber;
  int16_t angle;
  if (!parseInteger(servoText, servoNumber) || !parseInteger(angleText, angle) ||
      hasExtraToken() || servoNumber < 1 || servoNumber > SERVO_COUNT) {
    printError(F("ARGUMENT"));
    return;
  }

  const uint8_t index = (uint8_t)(servoNumber - 1);
  if (angle < SERVO_MIN[index] || angle > SERVO_MAX[index]) {
    Serial.print(F("ERR RANGE "));
    Serial.print(servoNumber);
    Serial.print(' ');
    Serial.print(SERVO_MIN[index]);
    Serial.print(' ');
    Serial.println(SERVO_MAX[index]);
    return;
  }

  doneRequested = false;
  setTarget(index, angle);
  Serial.print(F("OK SET "));
  Serial.print(servoNumber);
  Serial.print(' ');
  Serial.println(angle);
}

void handleMove() {
  if (emergencyStopped) {
    printError(F("ESTOP"));
    return;
  }

  int16_t angles[SERVO_COUNT];
  for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
    if (!parseInteger(strtok(NULL, " \t"), angles[i])) {
      printError(F("ARGUMENT"));
      return;
    }
    if (angles[i] < SERVO_MIN[i] || angles[i] > SERVO_MAX[i]) {
      Serial.print(F("ERR RANGE "));
      Serial.print(i + 1);
      Serial.print(' ');
      Serial.print(SERVO_MIN[i]);
      Serial.print(' ');
      Serial.println(SERVO_MAX[i]);
      return;
    }
  }
  if (hasExtraToken()) {
    printError(F("ARGUMENT"));
    return;
  }

  doneRequested = false;
  for (uint8_t i = 0; i < SERVO_COUNT; ++i) {
    setTarget(i, angles[i]);
  }
  Serial.println(F("OK MOVE"));
  doneRequested = true;
}

void handleLine(char *line) {
  char *command = strtok(line, " \t");
  if (command == NULL) {
    return;
  }

  if (strcmp(command, "SET") == 0) {
    handleSet();
  } else if (strcmp(command, "MOVE") == 0) {
    handleMove();
  } else if (strcmp(command, "STATUS") == 0 && !hasExtraToken()) {
    printStatus();
  } else if (strcmp(command, "LIMITS") == 0 && !hasExtraToken()) {
    printLimits();
  } else if (strcmp(command, "STOP") == 0 && !hasExtraToken()) {
    stopMotion();
    Serial.println(F("OK STOP"));
  } else if (strcmp(command, "ESTOP") == 0 && !hasExtraToken()) {
    stopMotion();
    emergencyStopped = true;
    Serial.println(F("OK ESTOP"));
  } else if (strcmp(command, "RESET") == 0 && !hasExtraToken()) {
    emergencyStopped = false;
    Serial.println(F("OK RESET"));
  } else if (strcmp(command, "DETACH") == 0 && !hasExtraToken()) {
    stopMotion();
    detachAll();
    Serial.println(F("OK DETACH"));
  } else if (strcmp(command, "PING") == 0 && !hasExtraToken()) {
    Serial.println(F("PONG"));
  } else {
    printError(F("COMMAND"));
  }
}

void readSerial() {
  while (Serial.available() > 0) {
    const char incoming = (char)Serial.read();
    if (incoming == '\r') {
      continue;
    }
    if (incoming == '\n') {
      if (lineOverflow) {
        printError(F("LINE_TOO_LONG"));
      } else if (lineLength > 0) {
        lineBuffer[lineLength] = '\0';
        handleLine(lineBuffer);
      }
      lineLength = 0;
      lineOverflow = false;
      continue;
    }

    if (!lineOverflow) {
      if (lineLength < LINE_SIZE - 1) {
        lineBuffer[lineLength++] = incoming;
      } else {
        lineOverflow = true;
      }
    }
  }
}

void setup() {
  Serial.begin(BAUD_RATE);
  lastStepAt = millis();

  // Servos deliberately remain detached. The first SET/MOVE command supplies
  // the initial pulse angle, so startup never assumes 0 or 90 degrees.
  Serial.println(F("READY 1"));
}

void loop() {
  readSerial();
  updateMotion();
}
