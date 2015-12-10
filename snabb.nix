{ config, pkgs, lib, ... }:

# Start with https://github.com/SnabbCo/snabbswitch/tree/master/src/program/snabbnfv/doc

with lib;

let
  snabb-neutron = pkgs.buildPythonPackage {
    name = "snabb-neutron-2015-12-09";

    src = pkgs.fetchFromGitHub {
      owner = "SnabbCo";
      repo = "snabb-neutron";
      rev = "f4723caccdb751ca3faf2dc47ed923348fcca997";
      sha256 = "0dc7gyh1j8956m0285csycaaxi2hj2yv7jkyirhfkblfparafyck";
    };

    propagatedBuildInputs = [ pkgs.neutron ];

  };
  snabb_dump_path = "/var/lib/snabb/";
  cfg = config.services.snabbswitch;
in {
  options.services.snabbswitch = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable snabbswitch NFV integration for Neutron.
        '';
      };
      ports = mkOption {
        type = types.listOf (types.attrsOf types.str);
        default = [];
        description = ''
          Ports configuration for Snabb.
        '';
        example = ''
          ports = [
            {
              pci = "0000:84:00.0";
              node = "1";
              cpu = "14";
              portid = "0";
            }
            {
              pci = "0000:84:00.1";
              node = "1";
              cpu = "15";
              portid = "1";
            }
          ];
        '';
      };
  };

  config = mkIf cfg.enable {
    # extend neutron with our plugin
    virtualisation.neutron.extraPackages = [ snabb-neutron ];

    # snabb required patch for qemu
    nixpkgs.config.packageOverrides = pkgs:
    {
      qemu = pkgs.qemu.overrideDerivation (super: {
        patches = super.patches ++ [ (pkgs.fetchurl {
          url = "https://github.com/SnabbCo/qemu/commit/f393aea2301734647fdf470724433f44702e3fb9.patch";
          sha256 = "0hpnfdk96rrdaaf6qr4m4pgv40dw7r53mg95f22axj7nsyr8d72x";
        })];
      });
    };


    # one traffic instance per 10G port
    systemd.services = let
      mkService = portspec:
        {
          name = "snabb-nfv-traffic-${portspec.portid}";
          value = {
            description = "";
            after = [ "snabb-neutron-sync-master.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig.ExecStart = "${pkgs.utillinux}/bin/taskset -c ${portspec.cpu} ${pkgs.snabbswitch}/bin/snabb snabbnfv traffic pci=${portspec.pci} node=${portspec.node} cpu=${portspec.cpu} portid=${portspec.portid}";
            # https://github.com/SnabbCo/snabbswitch/blob/master/src/program/snabbnfv/doc/installation.md#traffic-restarts
            serviceConfig.Restart = "on-failure";
          };
        };
    in builtins.listToAttrs (map mkService cfg.ports) //
    {
      snabb-neutron-sync-master = {
        description = "";
        after = [ "mysql.service" "neutron-server.service" ];
        wantedBy = [ "multi-user.target" ];
        environment = {
          DB_USER = "neutron";
          DB_PASSWORD = "neutron";  # TODO: CHANGEME!
          DB_DUMP_PATH = snabb_dump_path;
          DB_NEUTRON = "neutron";
        };
        serviceConfig.ExecStart = "${pkgs.snabbswitch}/bin/snabb snabbnfv neutron-sync-master";
      };

      snabb-neutron-sync-agent = {
        description = "";
        wantedBy = [ "multi-user.target" ];
        environment = {
          NEUTRON_DIR = "/var/lib/neutron";
          SNABB_DIR = snabb_dump_path;
          NEUTRON2SNABB = "${pkgs.snabbswitch}/bin/snabb snabbnfv neutron2snabb";
          SYNC_PATH = "";
          SYNC_HOST = "127.0.0.1";
        };
        serviceConfig.ExecStart = "${pkgs.snabbswitch}/bin/snabb snabbnfv neutron-sync-agent";
      };
    };
  };
}