# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose::project' do
  let(:title) { 'demo' }
  let(:pre_condition) { 'include podman_compose' }

  def rootful_compose_params
    {
      'rootless' => false,
      'compose'  => { 'services' => { 'web' => { 'image' => 'nginx:1.27' } } },
    }
  end

  def verify_images_script
    '/opt/compose/demo/.puppet-verify-images.sh'
  end

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'rootful, minimal compose' do
        let(:params) do
          {
            'rootless' => false,
            'compose'  => {
              'services' => {
                'web' => { 'image' => 'nginx:1.27' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/opt/compose/demo') }
        it { is_expected.to contain_file('/etc/systemd/system/podman-compose-demo.service') }
      end

      context 'with proxy_env (rootful)' do
        let(:params) do
          rootful_compose_params.merge(
            'proxy_env' => {
              'HTTPS_PROXY' => 'http://proxy:3128',
              'NO_PROXY'    => 'localhost,127.0.0.1',
            },
          )
        end

        it { is_expected.to compile.with_all_deps }

        it 'renders proxy Environment= lines into the systemd unit so pull/up use the proxy' do
          is_expected.to contain_file('/etc/systemd/system/podman-compose-demo.service')
            .with_content(%r{Environment="HTTPS_PROXY=http://proxy:3128"})
            .with_content(%r{Environment="NO_PROXY=localhost,127.0.0.1"})
        end

        it 'injects the proxy into the rolling-update exec environment' do
          expect(catalogue.resource('Exec', 'podman-compose-restart-demo')[:environment])
            .to include('HTTPS_PROXY=http://proxy:3128', 'NO_PROXY=localhost,127.0.0.1')
        end

        it 'injects the proxy into the drift-verify exec environment' do
          expect(catalogue.resource('Exec', 'podman-compose-verify-demo')[:environment])
            .to include('HTTPS_PROXY=http://proxy:3128', 'NO_PROXY=localhost,127.0.0.1')
        end
      end

      context 'rootless requires user' do
        let(:params) do
          {
            'rootless' => true,
            'compose'  => {
              'services' => {
                'web' => { 'image' => 'nginx:1.27' },
              },
            },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{'user' is required when rootless}) }
      end

      context 'rootless with user' do
        let(:params) do
          {
            'rootless'     => true,
            'user'         => 'appuser',
            'subuid_start' => 100_000,
            'subgid_start' => 100_000,
            'compose'      => {
              'services' => {
                'web' => { 'image' => 'nginx:1.27' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__user('appuser') }
      end

      context 'shared user across multiple projects' do
        # Regression: two rootless projects owned by the same user must not
        # raise a duplicate Podman_compose::User declaration.
        let(:pre_condition) do
          <<~PP
            include podman_compose
            podman_compose::project { 'other':
              rootless     => true,
              user         => 'appuser',
              subuid_start => 100000,
              subgid_start => 100000,
              compose      => { 'services' => { 'api' => { 'image' => 'busybox' } } },
            }
          PP
        end
        let(:params) do
          {
            'rootless'     => true,
            'user'         => 'appuser',
            'subuid_start' => 100_000,
            'subgid_start' => 100_000,
            'compose'      => {
              'services' => {
                'web' => { 'image' => 'nginx:1.27' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__user('appuser') }
      end

      context 'shared registry across multiple projects' do
        # Regression: two rootless projects sharing the same user and
        # registry must not raise a duplicate Podman_compose::Registry
        # declaration, even though their compose dirs differ.
        let(:pre_condition) do
          <<~PP
            include podman_compose
            podman_compose::project { 'other':
              rootless     => true,
              user         => 'appuser',
              subuid_start => 100000,
              subgid_start => 100000,
              registries   => { 'harbor.example' => { 'username' => 'robot', 'password' => Sensitive('secret') } },
              compose      => { 'services' => { 'api' => { 'image' => 'harbor.example/api' } } },
            }
          PP
        end
        let(:params) do
          {
            'rootless'     => true,
            'user'         => 'appuser',
            'subuid_start' => 100_000,
            'subgid_start' => 100_000,
            'registries'   => { 'harbor.example' => { 'username' => 'robot', 'password' => sensitive('secret') } },
            'compose'      => {
              'services' => {
                'web' => { 'image' => 'harbor.example/web' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__registry('appuser@harbor.example') }
      end

      context 'search registries (unqualified-search-registries)' do
        context 'rootless default manages docker.io for the user' do
          let(:params) do
            {
              'rootless'     => true,
              'user'         => 'appuser',
              'subuid_start' => 100_000,
              'subgid_start' => 100_000,
              'compose'      => { 'services' => { 'web' => { 'image' => 'nginx:1.27' } } },
            }
          end

          it { is_expected.to compile.with_all_deps }

          it 'writes registries.conf into the user home with docker.io' do
            is_expected.to contain_file('/home/appuser/.config/containers/registries.conf')
              .with_content(%r{unqualified-search-registries = \["docker\.io"\]})
              .with_content(%r{short-name-mode = "permissive"})
          end

          it 'orders registries.conf before the compose file' do
            is_expected.to contain_file('/home/appuser/.config/containers/registries.conf')
              .that_comes_before('File[/home/appuser/compose/demo/compose.yml]')
          end
        end

        context 'rootful manages /root registries.conf' do
          let(:params) do
            {
              'rootless' => false,
              'compose'  => { 'services' => { 'web' => { 'image' => 'nginx:1.27' } } },
            }
          end

          it { is_expected.to compile.with_all_deps }
          it { is_expected.to contain_file('/root/.config/containers/registries.conf') }
        end

        context 'custom search_registries list' do
          let(:params) do
            {
              'rootless'          => true,
              'user'              => 'appuser',
              'subuid_start'      => 100_000,
              'subgid_start'      => 100_000,
              'search_registries' => ['docker.io', 'ghcr.io'],
              'compose'           => { 'services' => { 'web' => { 'image' => 'nginx:1.27' } } },
            }
          end

          it 'renders all registries in order' do
            is_expected.to contain_file('/home/appuser/.config/containers/registries.conf')
              .with_content(%r{unqualified-search-registries = \["docker\.io", "ghcr\.io"\]})
          end
        end

        context 'manage_search_registries => false' do
          let(:params) do
            {
              'rootless'                 => true,
              'user'                     => 'appuser',
              'subuid_start'             => 100_000,
              'subgid_start'             => 100_000,
              'manage_search_registries' => false,
              'compose'                  => { 'services' => { 'web' => { 'image' => 'nginx:1.27' } } },
            }
          end

          it { is_expected.to compile.with_all_deps }
          it { is_expected.not_to contain_file('/home/appuser/.config/containers/registries.conf') }
        end

        context 'shared user across projects does not duplicate registries.conf' do
          let(:pre_condition) do
            <<~PP
              include podman_compose
              podman_compose::project { 'other':
                rootless     => true,
                user         => 'appuser',
                subuid_start => 100000,
                subgid_start => 100000,
                compose      => { 'services' => { 'api' => { 'image' => 'busybox' } } },
              }
            PP
          end
          let(:params) do
            {
              'rootless'     => true,
              'user'         => 'appuser',
              'subuid_start' => 100_000,
              'subgid_start' => 100_000,
              'compose'      => { 'services' => { 'web' => { 'image' => 'nginx:1.27' } } },
            }
          end

          it { is_expected.to compile.with_all_deps }
          it { is_expected.to contain_file('/home/appuser/.config/containers/registries.conf') }
        end
      end

      context 'compose hash missing services' do
        let(:params) do
          {
            'rootless' => false,
            'compose'  => { 'version' => '3' },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{must contain a 'services' key}) }
      end

      context 'ensure => absent' do
        let(:params) do
          {
            'ensure'   => 'absent',
            'rootless' => false,
            'compose'  => {
              'services' => {
                'web' => { 'image' => 'nginx:1.27' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/opt/compose/demo').with_ensure('absent') }

        it 'tears down even a legacy docker-compose.yml project' do
          down = catalogue.resource('Exec', 'podman-compose-down-demo')
          # Falls back to the legacy filename when compose.yml is absent...
          expect(down[:command]).to match(%r{docker-compose\.yml})
          # ...and the guard fires when either file exists.
          expect(down[:onlyif]).to match(%r{compose\.yml.*docker-compose\.yml})
        end
      end

      context 'recreate_strategy (rootful)' do
        context 'default is force-recreate' do
          let(:params) { rootful_compose_params }

          it { is_expected.to compile.with_all_deps }

          it 'force-recreates containers so env changes are applied cleanly' do
            is_expected.to contain_exec('podman-compose-restart-demo')
              .with_command(%r{up -d --force-recreate --remove-orphans})
          end
        end

        context 'rolling' do
          let(:params) { rootful_compose_params.merge('recreate_strategy' => 'rolling') }

          it 'uses a plain up -d without force-recreate' do
            cmd = catalogue.resource('Exec', 'podman-compose-restart-demo')[:command]
            expect(cmd).to match(%r{up -d --remove-orphans})
            expect(cmd).not_to match(%r{--force-recreate})
          end
        end

        context 'down-up' do
          let(:params) { rootful_compose_params.merge('recreate_strategy' => 'down-up') }

          it 'tears the project down then up so networks are re-created' do
            is_expected.to contain_exec('podman-compose-restart-demo')
              .with_command(%r{down && .* up -d --remove-orphans})
          end
        end

        context 'drift verify script uses the recreate strategy' do
          context 'default force-recreate' do
            let(:params) { rootful_compose_params }

            it 'force-recreates on drift so image-only changes are applied' do
              is_expected.to contain_file(verify_images_script)
                .with_content(%r{up -d --force-recreate --remove-orphans})
            end
          end

          context 'rolling' do
            let(:params) { rootful_compose_params.merge('recreate_strategy' => 'rolling') }

            it 'uses a plain up -d on drift' do
              content = catalogue.resource('File', verify_images_script)[:content]
              expect(content).to match(%r{up -d --remove-orphans})
              expect(content).not_to match(%r{--force-recreate})
            end
          end

          context 'down-up' do
            let(:params) { rootful_compose_params.merge('recreate_strategy' => 'down-up') }

            it 'tears down then up on drift' do
              is_expected.to contain_file(verify_images_script)
                .with_content(%r{down && .* up -d --remove-orphans})
            end
          end
        end
      end

      context 'recreate_strategy (rootless)' do
        let(:params) do
          {
            'rootless'          => true,
            'user'              => 'appuser',
            'subuid_start'      => 100_000,
            'subgid_start'      => 100_000,
            'recreate_strategy' => 'down-up',
            'compose'           => { 'services' => { 'web' => { 'image' => 'nginx:1.27' } } },
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'wraps the down-up sequence for the project user' do
          is_expected.to contain_exec('podman-compose-restart-demo')
            .with_command(%r{down && .* up -d --remove-orphans})
        end
      end
    end
  end
end
