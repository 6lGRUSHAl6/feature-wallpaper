#include <ctype.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static pid_t swaybg_pid = -1;

static void handle_signal(int signal_number) {
  (void)signal_number;
  running = 0;
}

static const char *extract_value(const char *json, const char *key, char *buffer, size_t size) {
  char pattern[128];
  snprintf(pattern, sizeof(pattern), "\"%s\"", key);

  const char *position = strstr(json, pattern);
  if (position == NULL) {
    return NULL;
  }

  position = strchr(position + strlen(pattern), ':');
  if (position == NULL) {
    return NULL;
  }

  while (*position != '\0' && (*position == ':' || isspace((unsigned char)*position))) {
    position++;
  }

  if (*position != '"') {
    return NULL;
  }

  position++;
  size_t index = 0;

  while (*position != '\0' && *position != '"' && index + 1 < size) {
    if (*position == '\\' && position[1] != '\0') {
      position++;
    }

    buffer[index++] = *position++;
  }

  buffer[index] = '\0';
  return buffer;
}

static void write_reply(const char *id, const char *status, const char *command, const char *message) {
  printf("{\"id\":\"%s\",\"status\":\"%s\",\"command\":\"%s\",\"message\":\"%s\"}\n", id, status, command, message);
  fflush(stdout);
}

static int command_exists(const char *command) {
  const char *path = getenv("PATH");
  if (path == NULL) {
    return 0;
  }

  char *paths = strdup(path);
  if (paths == NULL) {
    return 0;
  }

  int found = 0;
  char *save = NULL;
  for (char *segment = strtok_r(paths, ":", &save); segment != NULL; segment = strtok_r(NULL, ":", &save)) {
    char candidate[1024];
    snprintf(candidate, sizeof(candidate), "%s/%s", segment, command);
    if (access(candidate, X_OK) == 0) {
      found = 1;
      break;
    }
  }

  free(paths);
  return found;
}

static void terminate_swaybg(void) {
  if (swaybg_pid > 0) {
    kill(swaybg_pid, SIGTERM);
    waitpid(swaybg_pid, NULL, 0);
    swaybg_pid = -1;
  }
}

static int run_program(char *const argv[]) {
  pid_t pid = fork();
  if (pid < 0) {
    return -1;
  }

  if (pid == 0) {
    execvp(argv[0], argv);
    _exit(127);
  }

  int status = 0;
  if (waitpid(pid, &status, 0) < 0) {
    return -1;
  }

  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }

  return -1;
}

static void escape_js_string(const char *input, char *output, size_t size) {
  size_t index = 0;
  for (size_t i = 0; input[i] != '\0' && index + 2 < size; ++i) {
    unsigned char ch = (unsigned char)input[i];
    if (ch == '\\' || ch == '"') {
      output[index++] = '\\';
      output[index++] = (char)ch;
    } else if (ch == '\n' || ch == '\r' || ch == '\t') {
      output[index++] = ' ';
    } else {
      output[index++] = (char)ch;
    }
  }
  output[index] = '\0';
}

static void build_file_uri(const char *path, char *output, size_t size) {
  size_t index = 0;
  const char *prefix = "file://";
  for (size_t i = 0; prefix[i] != '\0' && index + 1 < size; ++i) {
    output[index++] = prefix[i];
  }

  for (size_t i = 0; path[i] != '\0' && index + 4 < size; ++i) {
    unsigned char ch = (unsigned char)path[i];
    if (ch == ' ') {
      output[index++] = '%';
      output[index++] = '2';
      output[index++] = '0';
    } else if (ch == '%') {
      output[index++] = '%';
      output[index++] = '2';
      output[index++] = '5';
    } else if (ch == '#') {
      output[index++] = '%';
      output[index++] = '2';
      output[index++] = '3';
    } else if (ch == '?') {
      output[index++] = '%';
      output[index++] = '3';
      output[index++] = 'F';
    } else {
      output[index++] = (char)ch;
    }
  }

  output[index] = '\0';
}

static const char *swaybg_mode(const char *scaling) {
  if (scaling == NULL) {
    return "fit";
  }

  if (strcmp(scaling, "fill") == 0) {
    return "fill";
  }

  if (strcmp(scaling, "stretch") == 0) {
    return "stretch";
  }

  if (strcmp(scaling, "center") == 0) {
    return "center";
  }

  if (strcmp(scaling, "tile") == 0) {
    return "fill";
  }

  return "fit";
}

static int apply_plasma_wallpaper(const char *path, char *error, size_t error_size) {
  char uri[2048];
  char escaped_uri[2048];
  char script[4096];
  char *const argv[] = {
    "gdbus",
    "call",
    "--session",
    "--dest",
    "org.kde.plasmashell",
    "--object-path",
    "/PlasmaShell",
    "--method",
    "org.kde.PlasmaShell.evaluateScript",
    script,
    NULL
  };

  build_file_uri(path, uri, sizeof(uri));
  escape_js_string(uri, escaped_uri, sizeof(escaped_uri));
  snprintf(
    script,
    sizeof(script),
    "var desktops = desktops();"
    "for (var i = 0; i < desktops.length; ++i) {"
    "  var d = desktops[i];"
    "  d.wallpaperPlugin = 'org.kde.image';"
    "  d.currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];"
    "  d.writeConfig('Image', '%s');"
    "  d.reloadConfig();"
    "}",
    escaped_uri
  );

  int rc = run_program(argv);
  if (rc != 0) {
    snprintf(error, error_size, "Plasma wallpaper update failed (exit %d)", rc);
    return -1;
  }

  terminate_swaybg();
  return 0;
}

static int apply_gsettings_wallpaper(const char *path, char *error, size_t error_size) {
  char uri[2048];
  build_file_uri(path, uri, sizeof(uri));

  char *const argv1[] = {
    "gsettings",
    "set",
    "org.gnome.desktop.background",
    "picture-uri",
    uri,
    NULL
  };

  char *const argv2[] = {
    "gsettings",
    "set",
    "org.gnome.desktop.background",
    "picture-uri-dark",
    uri,
    NULL
  };

  if (run_program(argv1) != 0) {
    snprintf(error, error_size, "gsettings picture-uri update failed");
    return -1;
  }

  run_program(argv2);
  terminate_swaybg();
  return 0;
}

static int apply_swaybg_wallpaper(const char *path, const char *scaling, char *error, size_t error_size) {
  char *const argv[] = {
    "swaybg",
    "-i",
    (char *)path,
    "-m",
    (char *)swaybg_mode(scaling),
    NULL
  };

  terminate_swaybg();

  pid_t pid = fork();
  if (pid < 0) {
    snprintf(error, error_size, "failed to start swaybg: %s", strerror(errno));
    return -1;
  }

  if (pid == 0) {
    execvp(argv[0], argv);
    _exit(127);
  }

  swaybg_pid = pid;
  return 0;
}

static int apply_wallpaper_backend(const char *path, const char *scaling, char *error, size_t error_size) {
  const char *desktop = getenv("XDG_CURRENT_DESKTOP");

  if (desktop != NULL && strstr(desktop, "KDE") != NULL && command_exists("gdbus")) {
    return apply_plasma_wallpaper(path, error, error_size);
  }

  if (getenv("WAYLAND_DISPLAY") != NULL && command_exists("swaybg")) {
    return apply_swaybg_wallpaper(path, scaling, error, error_size);
  }

  if (command_exists("gsettings")) {
    return apply_gsettings_wallpaper(path, error, error_size);
  }

  snprintf(error, error_size, "no supported wallpaper backend found");
  return -1;
}

int main(void) {
  signal(SIGTERM, handle_signal);
  signal(SIGINT, handle_signal);

  char line[4096];
  char id[256];
  char command[256];

  fprintf(stderr, "fw_renderer: ready\n");
  fflush(stderr);

  while (running && fgets(line, sizeof(line), stdin) != NULL) {
    id[0] = '\0';
    command[0] = '\0';

    if (extract_value(line, "id", id, sizeof(id)) == NULL) {
      strcpy(id, "0");
    }

    if (extract_value(line, "command", command, sizeof(command)) == NULL) {
      strcpy(command, "unknown");
    }

    fprintf(stderr, "fw_renderer: command=%s id=%s\n", command, id);
    fflush(stderr);

    if (strcmp(command, "shutdown") == 0) {
      write_reply(id, "ok", command, "renderer stopping");
      break;
    }

    if (strcmp(command, "ping") == 0) {
      write_reply(id, "ok", command, "pong from C renderer");
      continue;
    }

    if (strcmp(command, "apply") == 0) {
      char path[2048];
      char scaling[128];
      char error[512];

      if (extract_value(line, "path", path, sizeof(path)) == NULL) {
        path[0] = '\0';
      }

      if (extract_value(line, "scaling", scaling, sizeof(scaling)) == NULL) {
        scaling[0] = '\0';
      }

      if (path[0] == '\0') {
        write_reply(id, "error", "apply", "missing wallpaper path");
        continue;
      }

      if (apply_wallpaper_backend(path, scaling, error, sizeof(error)) == 0) {
        write_reply(id, "ok", "apply", "wallpaper applied");
      } else {
        write_reply(id, "error", "apply", error);
      }

      continue;
    }

    if (strcmp(command, "status") == 0) {
      write_reply(id, "ok", command, "renderer ready");
      continue;
    }

    write_reply(id, "error", command, "unsupported command");
  }

  fprintf(stderr, "fw_renderer: exit\n");
  fflush(stderr);
  return 0;
}
