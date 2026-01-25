# NixOS module for hyperscale monitoring stack
# Creates systemd-nspawn containers for Prometheus, Grafana, and Jaeger

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.hyperscale-monitoring;

  # Prometheus configuration generator
  prometheusConfig = pkgs.writeText "prometheus.yml" ''
    global:
      scrape_interval: 5s
      evaluation_interval: 5s

    scrape_configs:
      - job_name: 'hyperscale'
        static_configs:
          ${concatMapStringsSep "\n          " (target: "- targets: ['${target}']") cfg.validatorTargets}
        metrics_path: '/metrics'
        scrape_timeout: 5s
  '';

in {
  options.services.hyperscale-monitoring = {
    enable = mkEnableOption "Hyperscale monitoring stack";

    prometheusEnable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Prometheus";
    };

    grafanaEnable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Grafana";
    };

    jaegerEnable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Jaeger for distributed tracing";
    };

    validatorTargets = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "172.99.0.10:8080" "172.99.0.11:8080" ];
      description = "List of validator metrics endpoints (IP:port)";
    };

    prometheusPort = mkOption {
      type = types.int;
      default = 9090;
      description = "Prometheus web UI port";
    };

    grafanaPort = mkOption {
      type = types.int;
      default = 3000;
      description = "Grafana web UI port";
    };

    jaegerUIPort = mkOption {
      type = types.int;
      default = 16686;
      description = "Jaeger UI port";
    };

    jaegerOTLPPort = mkOption {
      type = types.int;
      default = 4317;
      description = "Jaeger OTLP gRPC receiver port";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/hyperscale/monitoring";
      description = "Directory for monitoring data";
    };

    bridgeName = mkOption {
      type = types.str;
      default = "br-hyperscale";
      description = "Network bridge name (same as validators)";
    };

    prometheusIP = mkOption {
      type = types.str;
      default = "172.99.0.5";
      description = "Static IP for Prometheus container";
    };

    grafanaIP = mkOption {
      type = types.str;
      default = "172.99.0.6";
      description = "Static IP for Grafana container";
    };

    jaegerIP = mkOption {
      type = types.str;
      default = "172.99.0.7";
      description = "Static IP for Jaeger container";
    };

    grafanaConfigPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to Grafana provisioning directory";
    };

    grafanaDashboardsPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to Grafana dashboards directory";
    };
  };

  config = mkIf cfg.enable {
    # Create monitoring data directories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/prometheus 0755 65534 65534 -"  # nobody user
      "d ${cfg.dataDir}/grafana 0755 472 472 -"  # grafana user
    ];

    # Prometheus container
    containers.hyperscale-prometheus = mkIf cfg.prometheusEnable {
      autoStart = true;
      privateNetwork = false;

      bindMounts = {
        "/etc/prometheus/prometheus.yml" = {
          hostPath = prometheusConfig;
          isReadOnly = true;
        };
        "/prometheus" = {
          hostPath = "${cfg.dataDir}/prometheus";
          isReadOnly = false;
        };
      };

      extraVeths.ve-prometheus = {
        localAddress = cfg.prometheusIP;
        hostBridge = cfg.bridgeName;
      };

      config = { config, pkgs, ... }: {
        system.stateVersion = "24.05";

        services.prometheus = {
          enable = true;
          port = cfg.prometheusPort;
          configText = builtins.readFile prometheusConfig;
          stateDir = "/prometheus";
          retentionTime = "7d";
          extraFlags = [
            "--web.enable-lifecycle"
            "--storage.tsdb.path=/prometheus"
          ];
        };

        networking.firewall.allowedTCPPorts = [ cfg.prometheusPort ];
      };
    };

    # Grafana container
    containers.hyperscale-grafana = mkIf cfg.grafanaEnable {
      autoStart = true;
      privateNetwork = false;

      bindMounts = {
        "/var/lib/grafana" = {
          hostPath = "${cfg.dataDir}/grafana";
          isReadOnly = false;
        };
      } // optionalAttrs (cfg.grafanaConfigPath != null) {
        "/etc/grafana/provisioning" = {
          hostPath = cfg.grafanaConfigPath;
          isReadOnly = true;
        };
      } // optionalAttrs (cfg.grafanaDashboardsPath != null) {
        "/var/lib/grafana/dashboards" = {
          hostPath = cfg.grafanaDashboardsPath;
          isReadOnly = true;
        };
      };

      extraVeths.ve-grafana = {
        localAddress = cfg.grafanaIP;
        hostBridge = cfg.bridgeName;
      };

      config = { config, pkgs, ... }: {
        system.stateVersion = "24.05";

        services.grafana = {
          enable = true;
          settings = {
            server = {
              http_addr = "0.0.0.0";
              http_port = cfg.grafanaPort;
            };
            security = {
              admin_user = "admin";
              admin_password = "admin";
            };
            users = {
              allow_sign_up = false;
            };
            "auth.anonymous" = {
              enabled = true;
              org_role = "Admin";
            };
            "auth" = {
              disable_login_form = true;
            };
          };
          dataDir = "/var/lib/grafana";

          # Prometheus datasource
          provision = {
            enable = true;
            datasources.settings.datasources = [{
              name = "Prometheus";
              type = "prometheus";
              access = "proxy";
              url = "http://${cfg.prometheusIP}:${toString cfg.prometheusPort}";
              isDefault = true;
            }] ++ optionals cfg.jaegerEnable [{
              name = "Jaeger";
              type = "jaeger";
              access = "proxy";
              url = "http://${cfg.jaegerIP}:16685";
            }];
          };
        };

        networking.firewall.allowedTCPPorts = [ cfg.grafanaPort ];
      };
    };

    # Jaeger container (for distributed tracing)
    containers.hyperscale-jaeger = mkIf cfg.jaegerEnable {
      autoStart = true;
      privateNetwork = false;

      extraVeths.ve-jaeger = {
        localAddress = cfg.jaegerIP;
        hostBridge = cfg.bridgeName;
      };

      config = { config, pkgs, ... }: {
        system.stateVersion = "24.05";

        environment.systemPackages = with pkgs; [
          jaeger
        ];

        systemd.services.jaeger-all-in-one = {
          description = "Jaeger All-in-One";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];

          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.jaeger}/bin/jaeger-all-in-one";
            Restart = "always";
            RestartSec = "5s";
          };

          environment = {
            COLLECTOR_OTLP_ENABLED = "true";
            MEMORY_MAX_TRACES = "10000000";
            SPAN_STORAGE_TYPE = "memory";
          };
        };

        networking.firewall.allowedTCPPorts = [
          cfg.jaegerUIPort      # UI
          cfg.jaegerOTLPPort    # OTLP gRPC
          4318                  # OTLP HTTP
          16685                 # gRPC query (for Grafana)
        ];
      };
    };

    # Port forwarding on host for external access
    networking.firewall.allowedTCPPorts =
      optional cfg.prometheusEnable cfg.prometheusPort ++
      optional cfg.grafanaEnable cfg.grafanaPort ++
      optionals cfg.jaegerEnable [ cfg.jaegerUIPort cfg.jaegerOTLPPort ];
  };
}
