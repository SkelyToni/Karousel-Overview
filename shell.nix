{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  packages = [ pkgs.python3 pkgs.nodejs pkgs.kdePackages.qtdeclarative ];
}
