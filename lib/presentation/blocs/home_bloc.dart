import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:dramabox_free/core/constants/app_enums.dart';
import 'package:dramabox_free/data/models/drama_model.dart';
import 'package:dramabox_free/data/models/drama_section_model.dart';
import 'package:dramabox_free/domain/repositories/drama_repository.dart';
import 'package:dramabox_free/core/network/rate_limit_exception.dart';

// Events
abstract class HomeEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class FetchHomeDataEvent extends HomeEvent {
  final AppContentProvider provider;
  final bool forceRefresh;
  FetchHomeDataEvent({
    this.provider = AppContentProvider.dramabox,
    this.forceRefresh = false,
  });

  @override
  List<Object?> get props => [provider, forceRefresh];
}

class PreloadAllEvent extends HomeEvent {}

class LoadMoreHomeDataEvent extends HomeEvent {
  final AppContentProvider provider;
  final int sectionIndex;

  LoadMoreHomeDataEvent({required this.provider, required this.sectionIndex});

  @override
  List<Object?> get props => [provider, sectionIndex];
}

class SearchDramasEvent extends HomeEvent {
  final String query;
  final AppContentProvider provider;
  SearchDramasEvent(this.query, {this.provider = AppContentProvider.dramabox});

  @override
  List<Object?> get props => [query, provider];
}

// States
abstract class HomeState extends Equatable {
  @override
  List<Object?> get props => [];
}

class HomeInitial extends HomeState {}

class HomeLoading extends HomeState {}

class HomeLoaded extends HomeState {
  final Map<AppContentProvider, List<DramaSectionModel>> providerSections;
  final List<DramaModel>? searchResults;

  HomeLoaded({required this.providerSections, this.searchResults});

  List<DramaSectionModel> get sectionsForDramabox =>
      providerSections[AppContentProvider.dramabox] ?? [];
  List<DramaSectionModel> get sectionsForNetshort =>
      providerSections[AppContentProvider.netshort] ?? [];

  HomeLoaded copyWith({
    Map<AppContentProvider, List<DramaSectionModel>>? providerSections,
    List<DramaModel>? searchResults,
  }) {
    return HomeLoaded(
      providerSections: providerSections ?? this.providerSections,
      searchResults: searchResults ?? this.searchResults,
    );
  }

  @override
  List<Object?> get props => [providerSections, searchResults];
}

class HomeError extends HomeState {
  final String message;
  final bool isApiBlocked;
  HomeError(this.message, {this.isApiBlocked = false});

  @override
  List<Object?> get props => [message, isApiBlocked];
}

// Bloc
class HomeBloc extends Bloc<HomeEvent, HomeState> {
  final DramaRepository repository;

  HomeBloc({required this.repository}) : super(HomeInitial()) {
    on<PreloadAllEvent>((event, emit) async {
      final providers = [
        AppContentProvider.dramabox,
        AppContentProvider.netshort,
      ];

      Map<AppContentProvider, List<DramaSectionModel>> sectionsMap = {};
      if (state is HomeLoaded) {
        sectionsMap = Map.of((state as HomeLoaded).providerSections);
      }

      // 1. Load cached for both first
      for (final provider in providers) {
        final cached = await repository.getCachedHomeSections(
          provider: provider,
        );
        if (cached != null && cached.isNotEmpty) {
          sectionsMap[provider] = cached;
        }
      }

      if (sectionsMap.isNotEmpty) {
        emit(HomeLoaded(providerSections: sectionsMap));
      } else {
        emit(HomeLoading());
      }

      // 2. Fetch fresh for both
      await Future.wait(
        providers.map((provider) async {
          try {
            final sections = await repository.getHomeSections(
              provider: provider,
            );
            sectionsMap[provider] = sections;
            if (state is HomeLoaded) {
              final s = state as HomeLoaded;
              emit(
                s.copyWith(
                  providerSections: Map.of(sectionsMap),
                  searchResults: s.searchResults,
                ),
              );
            } else {
              emit(HomeLoaded(providerSections: Map.of(sectionsMap)));
            }
          } catch (e) {
            debugPrint("Error preloading $provider: $e");
          }
        }),
      );
    });

    on<FetchHomeDataEvent>((event, emit) async {
      final provider = event.provider;

      if (state is! HomeLoaded) {
        emit(HomeLoading());
      }

      try {
        final sections = await repository.getHomeSections(provider: provider);
        final sectionsMap = state is HomeLoaded
            ? Map.of((state as HomeLoaded).providerSections)
            : <AppContentProvider, List<DramaSectionModel>>{};

        sectionsMap[provider] = sections;

        if (state is HomeLoaded) {
          emit((state as HomeLoaded).copyWith(providerSections: sectionsMap));
        } else {
          emit(HomeLoaded(providerSections: sectionsMap));
        }
      } catch (e) {
        if (state is! HomeLoaded) {
          emit(_errorFromException(e));
        }
      }
    });

    on<LoadMoreHomeDataEvent>((event, emit) async {
      if (state is! HomeLoaded) return;
      final currentState = state as HomeLoaded;

      final provider = event.provider;
      final sectionsMap = Map<AppContentProvider, List<DramaSectionModel>>.from(
        currentState.providerSections,
      );
      final sections = List<DramaSectionModel>.from(
        sectionsMap[provider] ?? [],
      );

      if (event.sectionIndex >= sections.length) return;

      final section = sections[event.sectionIndex];
      // Only For You supports pagination for Dramabox
      if (provider == AppContentProvider.dramabox &&
          section.name != 'For You') {
        return;
      }

      if (!section.hasMore) return;

      final nextPage = section.currentPage + 1;

      try {
        final List<DramaModel> moreDramas;
        if (provider == AppContentProvider.dramabox) {
          moreDramas = await repository.getForYouDramas(
            provider: provider,
            page: nextPage,
          );
        } else {
          // Use Trending as ForYou for Netshort as per current repository mapping
          moreDramas = await repository.getTrendingDramas(
            provider: provider,
            page: nextPage,
          );
        }

        if (moreDramas.isEmpty) {
          sections[event.sectionIndex] = section.copyWith(hasMore: false);
        } else {
          sections[event.sectionIndex] = section.copyWith(
            dramas: [...section.dramas, ...moreDramas],
            currentPage: nextPage,
            // Assuming 10+ items means there might be more
            hasMore: moreDramas.length >= 10,
          );
        }

        sectionsMap[provider] = sections;
        emit(currentState.copyWith(providerSections: sectionsMap));
      } catch (e) {
        debugPrint("Error loading more dramas: $e");
      }
    });

    on<SearchDramasEvent>((event, emit) async {
      final provider = event.provider;
      if (event.query.isEmpty) {
        add(FetchHomeDataEvent(provider: provider));
        return;
      }

      final currentState = state;

      emit(HomeLoading());
      try {
        final searchResults = await repository.searchDramas(
          event.query,
          provider: provider,
        );
        final sectionsMap = currentState is HomeLoaded
            ? currentState.providerSections
            : <AppContentProvider, List<DramaSectionModel>>{};

        emit(
          HomeLoaded(
            providerSections: sectionsMap,
            searchResults: searchResults,
          ),
        );
      } catch (e) {
        emit(_errorFromException(e));
      }
    });
  }

  HomeError _errorFromException(Object e) {
    if (e is ApiBlockedException) {
      return HomeError(e.message, isApiBlocked: true);
    }
    if (e is DioException && e.error is ApiBlockedException) {
      final abe = e.error as ApiBlockedException;
      return HomeError(abe.message, isApiBlocked: true);
    }
    return HomeError(e.toString());
  }
}
